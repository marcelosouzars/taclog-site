// PUSH_FCM.JS
// Envio de notificações push (Firebase Cloud Messaging, API HTTP v1) para o
// celular do motorista e da gestora — chegam mesmo com a tela bloqueada e o
// aplicativo fechado. Não depende de nenhum pacote novo: usa o
// jsonwebtoken (que o servidor já tem) e o fetch nativo do Node 18+.
//
// Configuração (no Render, em Environment):
//   FIREBASE_SERVICE_ACCOUNT = conteúdo INTEIRO do arquivo .json da conta de
//   serviço do Firebase (ou esse mesmo conteúdo codificado em base64).
//
// Sem essa variável o módulo fica desligado e o servidor funciona normal.

module.exports = function criarPush({ pool, jwt }) {
    let credencial = null;

    function carregarCredencial() {
        const bruto = (process.env.FIREBASE_SERVICE_ACCOUNT || '').trim();
        if (!bruto) return null;
        try {
            const texto = bruto.startsWith('{') ? bruto : Buffer.from(bruto, 'base64').toString('utf8');
            const c = JSON.parse(texto);
            if (!c.client_email || !c.private_key || !c.project_id) {
                console.error('[PUSH] FIREBASE_SERVICE_ACCOUNT incompleta (faltam client_email, private_key ou project_id).');
                return null;
            }
            // Quando o JSON é colado numa variável de ambiente, as quebras de
            // linha da chave às vezes chegam como "\n" literal.
            c.private_key = String(c.private_key).replace(/\\n/g, '\n');
            return c;
        } catch (e) {
            console.error('[PUSH] FIREBASE_SERVICE_ACCOUNT inválida:', e.message);
            return null;
        }
    }

    credencial = carregarCredencial();
    if (credencial) console.log('[PUSH] Firebase configurado (projeto ' + credencial.project_id + ').');
    else console.log('[PUSH] Firebase NÃO configurado — notificações push desligadas.');

    function configurado() {
        return !!credencial;
    }

    // ---- token de acesso do Google (vale 1 hora, guardado em memória) ----
    let tokenAcesso = { valor: null, expira: 0 };

    async function obterTokenAcesso() {
        if (tokenAcesso.valor && Date.now() < tokenAcesso.expira - 60000) return tokenAcesso.valor;
        const agora = Math.floor(Date.now() / 1000);
        const assertion = jwt.sign(
            {
                iss: credencial.client_email,
                scope: 'https://www.googleapis.com/auth/firebase.messaging',
                aud: 'https://oauth2.googleapis.com/token',
                iat: agora,
                exp: agora + 3600,
            },
            credencial.private_key,
            { algorithm: 'RS256' }
        );
        const r = await fetch('https://oauth2.googleapis.com/token', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
                grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                assertion,
            }).toString(),
        });
        const j = await r.json().catch(() => ({}));
        if (!r.ok || !j.access_token) {
            throw new Error('Google recusou a credencial: ' + (j.error_description || j.error || r.status));
        }
        tokenAcesso = { valor: j.access_token, expira: Date.now() + (j.expires_in || 3600) * 1000 };
        return tokenAcesso.valor;
    }

    // ---- envio de uma mensagem para UM aparelho ----
    // Devolve { ok: true } ou { ok: false, tokenInvalido: bool, erro: texto }.
    async function enviarParaToken(token, titulo, corpo, dados = {}) {
        const acesso = await obterTokenAcesso();
        const dadosTexto = {};
        for (const k of Object.keys(dados)) {
            if (dados[k] !== null && dados[k] !== undefined) dadosTexto[k] = String(dados[k]);
        }
        const mensagem = {
            token,
            notification: { title: titulo, body: corpo },
            data: dadosTexto,
            android: {
                priority: 'HIGH',
                notification: { channel_id: 'taclog_avisos', sound: 'default' },
            },
            webpush: {
                headers: { Urgency: 'high', TTL: '900' },
                notification: { requireInteraction: true },
            },
        };
        const r = await fetch(
            'https://fcm.googleapis.com/v1/projects/' + credencial.project_id + '/messages:send',
            {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + acesso },
                body: JSON.stringify({ message: mensagem }),
            }
        );
        if (r.ok) return { ok: true };
        const e = await r.json().catch(() => ({}));
        const status = e && e.error && e.error.status;
        const detalhes = (e && e.error && e.error.details) || [];
        const invalido =
            status === 'NOT_FOUND' ||
            status === 'UNREGISTERED' ||
            detalhes.some((d) => d && d.errorCode === 'UNREGISTERED') ||
            (status === 'INVALID_ARGUMENT' && /registration token/i.test((e.error && e.error.message) || ''));
        return { ok: false, tokenInvalido: invalido, erro: (e && e.error && e.error.message) || String(r.status) };
    }

    // ---- envio para todos os aparelhos ativos de um usuário ----
    async function enviarParaUsuario(tipoUsuario, usuarioId, titulo, corpo, dados = {}) {
        if (!credencial) return { enviados: 0, falhas: 0, semAparelho: true, naoConfigurado: true };
        const aparelhos = await pool.query(
            'SELECT id, token FROM dispositivos_push WHERE tipo_usuario = $1 AND usuario_id = $2 AND ativo = TRUE',
            [tipoUsuario, usuarioId]
        );
        let enviados = 0;
        let falhas = 0;
        let ultimoErro = null;
        for (const ap of aparelhos.rows) {
            try {
                const r = await enviarParaToken(ap.token, titulo, corpo, dados);
                if (r.ok) {
                    enviados++;
                } else {
                    falhas++;
                    ultimoErro = r.erro;
                    if (r.tokenInvalido) {
                        await pool.query('UPDATE dispositivos_push SET ativo = FALSE, atualizado_em = NOW() WHERE id = $1', [ap.id]);
                    }
                }
            } catch (e) {
                falhas++;
                ultimoErro = e.message;
            }
        }
        return { enviados, falhas, semAparelho: aparelhos.rows.length === 0, ultimoErro };
    }

    // ---- cadastro dos aparelhos ----
    async function registrarAparelho(tipoUsuario, usuarioId, token, plataforma) {
        await pool.query(
            `INSERT INTO dispositivos_push (tipo_usuario, usuario_id, token, plataforma, ativo, atualizado_em)
             VALUES ($1, $2, $3, $4, TRUE, NOW())
             ON CONFLICT (token) DO UPDATE
             SET tipo_usuario = EXCLUDED.tipo_usuario, usuario_id = EXCLUDED.usuario_id,
                 plataforma = EXCLUDED.plataforma, ativo = TRUE, atualizado_em = NOW()`,
            [tipoUsuario, usuarioId, token, plataforma || null]
        );
    }

    async function removerAparelho(token) {
        await pool.query('UPDATE dispositivos_push SET ativo = FALSE, atualizado_em = NOW() WHERE token = $1', [token]);
    }

    // ---- varredura: manda push dos avisos novos ----
    // Todo aviso que o sistema grava em notificacoes_motorista /
    // notificacoes_gestor (hoje e no futuro) vira push automaticamente, sem
    // precisar mexer nos pontos que criam os avisos. Só vão avisos de até 15
    // minutos atrás (aviso velho demais não faz sentido tocar no celular).
    const TITULOS = {
        COLETAR_AGORA: 'Hora da coleta',
        GERAL: 'TACLOG — novo aviso',
    };
    function tituloDoAviso(tipo) {
        return TITULOS[tipo] || 'TACLOG — novo aviso';
    }

    let rodando = false;

    async function processar(tabela, colUsuario, tipoUsuario) {
        const avisos = await pool.query(
            `SELECT id, ${colUsuario} AS usuario_id, mensagem, tipo, referencia_id, referencia_origem
             FROM ${tabela}
             WHERE push_enviado_em IS NULL AND lida = FALSE
               AND data_criacao > NOW() - INTERVAL '15 minutes'
             ORDER BY id ASC LIMIT 50`
        );
        for (const a of avisos.rows) {
            // Marca ANTES de enviar: se o envio demorar, a próxima varredura
            // não manda o mesmo aviso duas vezes.
            const marcou = await pool.query(
                `UPDATE ${tabela} SET push_enviado_em = NOW() WHERE id = $1 AND push_enviado_em IS NULL RETURNING id`,
                [a.id]
            );
            if (marcou.rows.length === 0) continue;
            try {
                await enviarParaUsuario(tipoUsuario, a.usuario_id, tituloDoAviso(a.tipo), a.mensagem, {
                    tipo: a.tipo || 'GERAL',
                    referencia_id: a.referencia_id,
                    referencia_origem: a.referencia_origem,
                    aviso_id: a.id,
                    destino: tipoUsuario === 'GESTOR' ? 'gestor' : 'motorista',
                });
            } catch (e) {
                console.error('[PUSH] erro ao enviar aviso ' + a.id + ' (' + tabela + '):', e.message);
            }
        }
    }

    async function enviarPendentes() {
        if (!credencial || rodando) return;
        rodando = true;
        try {
            await processar('notificacoes_motorista', 'motorista_id', 'MOTORISTA');
            await processar('notificacoes_gestor', 'funcionario_id', 'GESTOR');
        } catch (e) {
            console.error('[PUSH] erro na varredura:', e.message);
        } finally {
            rodando = false;
        }
    }

    return { configurado, enviarParaUsuario, registrarAparelho, removerAparelho, enviarPendentes };
};
