
//
require('dotenv').config();
const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
// const bcrypt = require('bcrypt'); // Removido temporariamente para a apresentação
const multer = require('multer');
const jwt = require('jsonwebtoken');
const PDFDocument = require('pdfkit');
const fs = require('fs');
const path = require('path');
const cloudinary = require('cloudinary').v2;
const TERMOS = require('./termos_taclog');
const app = express();
const port = process.env.PORT || 3000;

const JWT_SECRET = process.env.JWT_SECRET || 'segredo_super_seguro_do_taclog_v5_enterprise';

// NOVO: nome de quem está realmente fazendo a ação (pra registrar em
// cargas/coletas/agendamentos) — funcionário logado usa o próprio nome;
// o titular (dono da conta, sem funcionario_id no token) usa o nome do
// responsável cadastrado no admin, e se não tiver, cai pro nome da empresa.
function nomeDoAtor(req) {
    return req.user.funcionario_nome || req.user.admin_nome || req.user.nome || null;
}

// =========================================================================
// NOVO: PERFIS DE ACESSO (ADMIN / OPERADOR)
//
// O titular da conta (quem loga direto com CNPJ — não tem funcionario_id
// no token) é sempre administrador, com poder total. Um funcionário
// cadastrado com perfil ADMIN tem o mesmo poder operacional do titular
// (cadastrar E excluir motoristas/caminhões/carretas, cancelar carga já
// finalizada). Um funcionário OPERADOR (perfil padrão) pode cadastrar e
// editar, mas não excluir essas coisas nem cancelar carga já finalizada —
// e nenhum dos dois perfis de funcionário gerencia outros funcionários
// (cadastrar/editar/resetar senha continua sendo só do titular).
// =========================================================================
function ehAdminEmbarcador(user) {
    return user.role === 'embarcador' && (!user.funcionario_id || user.perfil === 'ADMIN');
}

function exigirPerfilAdmin(req, res, next) {
    if (!ehAdminEmbarcador(req.user)) {
        return res.status(403).json({ error: 'Apenas administradores podem realizar esta ação.' });
    }
    next();
}

// =========================================================================
// NOVO: LOG DE ATIVIDADE (LOG DO SISTEMA)
//
// Por enquanto só registra o LOGIN — quem, quando, de onde (WEB ou APP) e,
// quando disponível, a coordenada de onde o login foi feito (hoje só o
// aplicativo do celular manda isso, e só se a permissão de localização já
// tiver sido concedida antes). Nunca deixa o login falhar por causa
// disso: erro aqui só vai pro console, o login segue normal.
// =========================================================================
async function registrarLogAtividade({ tipoUsuario, usuarioId, usuarioNome, perfil, origem, empresaId, lat, lng }) {
    try {
        await pool.query(
            `INSERT INTO logs_atividade (tipo_usuario, usuario_id, usuario_nome, perfil, origem, empresa_id, lat, lng)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
            [tipoUsuario, usuarioId, usuarioNome || null, perfil || null, origem || 'WEB', empresaId || null, lat ?? null, lng ?? null]
        );
    } catch (e) {
        console.error('Falha ao registrar log de atividade:', e.message);
    }
}

app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// =========================================================================
// CORRIGIDO: antes os arquivos (foto de perfil, logo, documento do
// caminhão) eram salvos em disco local (public/uploads/) — o Render
// apaga esse disco a cada novo deploy, e os arquivos simplesmente
// sumiam. Agora tudo sobe pra Cloudinary (storage externo, permanente)
// — o multer só segura o arquivo em memória por um instante antes de
// repassar pra lá, não grava mais nada localmente.
// =========================================================================
cloudinary.config({
    cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
    api_key: process.env.CLOUDINARY_API_KEY,
    api_secret: process.env.CLOUDINARY_API_SECRET,
});

const upload = multer({ storage: multer.memoryStorage() });

// Sobe um arquivo (buffer na memória) pro Cloudinary e devolve a URL
// pública. resourceType: 'image' pra fotos, 'raw' pra PDF (CNH,
// CRLV) — PDF como 'image' não funciona direito no Cloudinary.
function uploadParaCloudinary(buffer, pasta, resourceType = 'image') {
    return new Promise((resolve, reject) => {
        const streamUpload = cloudinary.uploader.upload_stream(
            { folder: pasta, resource_type: resourceType },
            (error, result) => {
                if (error) return reject(error);
                resolve(result.secure_url);
            }
        );
        streamUpload.end(buffer);
    });
}

// Decide 'raw' (documentos/PDF) ou 'image' (fotos) pelo mimetype do
// arquivo recebido — evita ter que a tela dizer pro backend qual é.
function tipoDeRecursoCloudinary(file) {
    return file.mimetype === 'application/pdf' ? 'raw' : 'image';
}

const connectionString = process.env.DATABASE_URL || 'postgresql://neondb_owner:npg_4ypHr7fNwoCs@ep-curly-pine-aczt7iev-pooler.sa-east-1.aws.neon.tech/neondb?sslmode=require';
const pool = new Pool({ 
    connectionString: connectionString, 
    ssl: { rejectUnauthorized: false } 
});

// NOVO: notificações push (Firebase) — ver push_fcm.js. Fica desligado se a
// variável FIREBASE_SERVICE_ACCOUNT não estiver configurada no Render.
const push = require('./push_fcm')({ pool, jwt });

function authenticateToken(req, res, next) {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];
    if (token == null) return res.sendStatus(401);
    jwt.verify(token, JWT_SECRET, (err, user) => {
        if (err) return res.sendStatus(403);
        // NOVO: funcionário logado ainda com a senha provisória (a que o
        // administrador gerou) só pode chamar a rota de trocar a própria
        // senha — fica travado em qualquer outra ação até definir uma
        // senha definitiva.
        if (user.senha_provisoria === true && req.path !== '/api/funcionario/trocar-senha') {
            return res.status(403).json({ error: 'SENHA_PROVISORIA', message: 'Troque sua senha provisória antes de continuar.' });
        }
        req.user = user;
        next();
    });
}

// =========================================================================
// MIDDLEWARE: Exige que o embarcador logado seja do tipo Transportadora
// (is_transportadora = true no banco). Usado nas rotas de gestão de frota
// própria e configurações, que só fazem sentido para embarcadores que
// também são transportadoras (ex: ZANIN Transportes).
// =========================================================================
async function exigirTransportadora(req, res, next) {
    try {
        if (req.user.role !== 'embarcador') {
            return res.status(403).json({ error: 'Apenas embarcadores podem gerenciar frota.' });
        }
        const check = await pool.query('SELECT is_transportadora FROM embarcadores WHERE id = $1', [req.user.id]);
        if (check.rows.length === 0 || !check.rows[0].is_transportadora) {
            return res.status(403).json({ error: 'Este recurso é exclusivo para embarcadores do tipo Transportadora.' });
        }
        next();
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
}

// =========================================================================
// CADASTRO V2 — CAMPOS PERMITIDOS (whitelist usada nos INSERT/UPDATE
// dinâmicos de caminhões e carretas). Mantém as rotas curtas mesmo com
// o cadastro ficando cada vez mais completo — para adicionar um novo
// campo no futuro, basta acrescentar aqui e criar a coluna no banco.
// =========================================================================
const CAMPOS_CAMINHAO_PERMITIDOS = [
    'placa', 'renavam', 'chassi', 'marca', 'modelo', 'ano_fabricacao', 'ano_modelo', 'cor',
    'antt', 'rntrc', 'tipo_veiculo', 'classificacao_veiculo', 'tipo_unidade_tratora',
    'qtde_eixos', 'qtde_rodas', 'qtde_tanques', 'litros_tanque',
    'tara_kg', 'peso_carga_kg', 'volume_m3', 'altura_m', 'largura_m', 'comprimento_m', 'qtde_pallets',
    'km_inicial', 'numero_motor', 'tracao', 'tipo_combustivel', 'motorizacao_cv', 'cilindrada',
    'tipo_cambio', 'pbt_kg', 'pbtc_kg', 'capacidade_5a_roda_kg', 'tipo_vinculo',
    'crlv_numero', 'crlv_validade', 'rntrc_validade', 'categoria_rntrc',
    'seguradora', 'apolice_numero', 'apolice_validade', 'vistoria_data', 'vistoria_validade',
    'possui_rastreador', 'rastreador_modelo', 'rastreador_operadora',
    'habilitado_carga_indivisivel', 'habilitado_produtos_perigosos', 'tipo_composicao',
    // Classificação de mercado (tabelas tipos_veiculo / tipos_carroceria).
    // Só se aplicam ao caminhão RIGIDO — no CAVALO_MECANICO quem define a
    // carroceria é a carreta acoplada.
    'classificacao_carroceria'
];

const CAMPOS_CARRETA_PERMITIDOS = [
    'placa', 'renavam', 'chassi', 'marca_fabricante', 'modelo', 'ano_fabricacao', 'ano_modelo',
    'tipo_unidade', 'composicao', 'qtde_eixos', 'distancia_entre_eixos_m', 'possui_suspensao_pneumatica',
    'tipo_carroceria', 'tara_kg', 'peso_carga_kg', 'pbt_kg', 'volume_m3', 'comprimento_m', 'largura_m',
    'altura_m', 'qtde_pallets', 'atributos_especificos', 'certificado_produtos_perigosos',
    'tipo_vinculo', 'crlv_numero', 'crlv_validade',
    'seguradora', 'apolice_numero', 'apolice_validade', 'vistoria_data', 'vistoria_validade',
    // Classificação de mercado (tabelas tipos_veiculo / tipos_carroceria)
    'classificacao_veiculo', 'classificacao_carroceria'
];

function validarTipoUnidadeTratora(valor) {
    return valor === undefined || ['RIGIDO', 'CAVALO_MECANICO'].includes(valor);
}

// =========================================================================
// VERIFICAÇÃO DE E-MAIL — CONFIGURAÇÃO (Resend / API HTTP)
// =========================================================================
const RESEND_API_KEY = process.env.RESEND_API_KEY;
const EMAIL_REMETENTE = process.env.EMAIL_REMETENTE || 'TACLOG <onboarding@resend.dev>';

function gerarCodigoVerificacao() {
    return Math.floor(100000 + Math.random() * 900000).toString();
}

async function enviarEmailVerificacao(destinatario, nome, codigo) {
    if (!RESEND_API_KEY) {
        throw new Error('RESEND_API_KEY não configurada nas variáveis de ambiente.');
    }

    const html = `
        <div style="font-family: Arial, sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; border: 1px solid #e0e0e0; border-radius: 8px;">
            <h2 style="color:#1a3c6e;">Bem-vindo ao TACLOG, ${nome || ''}!</h2>
            <p>Use o código abaixo para confirmar seu cadastro:</p>
            <p style="font-size: 32px; font-weight: bold; letter-spacing: 6px; color:#1a3c6e; text-align:center; padding: 16px; background:#f2f6fc; border-radius: 8px;">${codigo}</p>
            <p>Digite esse código na tela de verificação para ativar sua conta.</p>
            <p style="color:#888; font-size: 12px;">Se você não solicitou este cadastro, pode ignorar este e-mail.</p>
        </div>
    `;

    const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({
            from: EMAIL_REMETENTE,
            to: [destinatario],
            subject: 'TACLOG - Código de Verificação de Cadastro',
            html: html
        })
    });

    if (!response.ok) {
        const erroTexto = await response.text();
        throw new Error(`Resend respondeu ${response.status}: ${erroTexto}`);
    }

    return response.json();
}

// =========================================================================
// E-mail genérico de aviso operacional pra transportadora — reaproveita
// o mesmo mecanismo (Resend) do e-mail de verificação, só que pra
// avisos do dia a dia (falta caminhão, falta destino, etc.), não
// cadastro. Nunca deixa derrubar o scheduler que chama — quem chama
// decide o que fazer se der erro.
// =========================================================================
async function enviarEmailAvisoOperacional(destinatario, assunto, corpoHtml) {
    if (!RESEND_API_KEY || !destinatario) return;

    const html = `
        <div style="font-family: Arial, sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; border: 1px solid #e0e0e0; border-radius: 8px;">
            <h2 style="color:#1a3c6e;">TACLOG — Aviso</h2>
            ${corpoHtml}
            <p style="color:#888; font-size: 12px; margin-top: 24px;">Esse é um aviso automático do TACLOG.</p>
        </div>
    `;

    const response = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: EMAIL_REMETENTE, to: [destinatario], subject: assunto, html: html })
    });
    if (!response.ok) {
        const erroTexto = await response.text();
        throw new Error(`Resend respondeu ${response.status}: ${erroTexto}`);
    }
    return response.json();
}

// --- ROTA TEMPORÁRIA PARA RESETAR SENHAS PARA 123456 ---
app.get('/api/resetar-senhas', async (req, res) => {
    try {
        await pool.query("UPDATE embarcadores SET senha_hash = '123456'");
        await pool.query("UPDATE motoristas SET senha_hash = '123456'");
        res.send("<h1>Sucesso!</h1><p>Todas as senhas de Embarcadores e Motoristas foram alteradas para <b>123456</b> no banco de dados.</p>");
    } catch (e) {
        res.status(500).send("Erro ao resetar senhas: " + e.message);
    }
});

// --- ROTAS DE LOGIN E CADASTRO CORPORATIVO ---
// NOVO: de onde veio o login, pro Log do Sistema — o app mobile manda
// "APP" e as telas web (embarcador e o painel web do motorista TAC) mandam
// "WEB". Se uma versão antiga ainda não mandar nada, cai num padrão
// razoável (embarcador só existe na web; motorista, por padrão, no app).
function normalizarOrigemLogin(origemRecebida, role) {
    const o = String(origemRecebida || '').toUpperCase();
    if (o === 'WEB' || o === 'APP') return o;
    return role === 'embarcador' ? 'WEB' : 'APP';
}

app.post('/api/login', async (req, res) => {
    const { cpf, usuario, senha, origem, lat, lng } = req.body;
    const login = String(cpf || usuario).trim();
    // NOVO: coordenada de onde o login foi feito (hoje só o app do
    // celular manda) — valida que são números de verdade antes de
    // repassar pro log, senão ignora silenciosamente.
    const latLogin = typeof lat === 'number' && isFinite(lat) ? lat : null;
    const lngLogin = typeof lng === 'number' && isFinite(lng) ? lng : null;

    try {
        let user = await pool.query('SELECT * FROM motoristas WHERE cpf = $1 ORDER BY id DESC LIMIT 1', [login]);
        let role = 'motorista';

        if (user.rows.length === 0) {
            // NOVO: funcionário da transportadora — cadastrado pelo
            // administrador, loga com o próprio CPF. Reaproveita toda a
            // lógica de embarcador já existente: o token carrega o
            // embarcador_id da empresa dona (pra tudo continuar sendo
            // filtrado do jeito que já era), mais os dados do funcionário
            // (funcionario_id/funcionario_nome), só pra registro de quem
            // fez a ação.
            const loginSoDigitos = login.replace(/\D/g, '');
            const func = await pool.query(
                `SELECT f.*, e.razao_social, e.is_transportadora, e.logo_url, e.usuario_login
                 FROM funcionarios_embarcador f
                 JOIN embarcadores e ON e.id = f.embarcador_id
                 WHERE f.cpf = $1
                 ORDER BY f.id DESC LIMIT 1`,
                [loginSoDigitos || login]
            );
            if (func.rows.length > 0) {
                const f = func.rows[0];
                if (f.status !== 'ATIVO') {
                    return res.status(403).json({
                        error: 'FUNCIONARIO_INATIVO',
                        message: f.status === 'SUSPENSO'
                            ? 'Seu acesso está suspenso no momento. Fale com o administrador da transportadora.'
                            : 'Seu acesso foi desativado. Fale com o administrador da transportadora.'
                    });
                }
                const dbSenhaFunc = String(f.senha_hash || '').trim();
                const reqSenhaFunc = String(senha || '').trim();
                if (reqSenhaFunc !== dbSenhaFunc) return res.status(401).json({ error: 'Senha incorreta' });

                const tokenFunc = jwt.sign({
                    id: f.embarcador_id,
                    role: 'embarcador',
                    nome: f.razao_social,
                    usuario: f.usuario_login,
                    is_transportadora: f.is_transportadora || false,
                    funcionario_id: f.id,
                    funcionario_nome: f.nome,
                    perfil: f.perfil || 'OPERADOR',
                    senha_provisoria: f.senha_provisoria,
                }, JWT_SECRET);

                // NOVO: Log do Sistema — registra o login do funcionário
                // (nunca deixa o login falhar por causa disso).
                registrarLogAtividade({
                    tipoUsuario: 'EMBARCADOR_FUNCIONARIO',
                    usuarioId: f.id,
                    usuarioNome: f.nome,
                    perfil: f.perfil || 'OPERADOR',
                    origem: normalizarOrigemLogin(origem, 'embarcador'),
                    empresaId: f.embarcador_id,
                });

                return res.json({
                    token: tokenFunc,
                    motorista_id: f.embarcador_id,
                    nome: f.razao_social,
                    funcionario_nome: f.nome,
                    role: 'embarcador',
                    perfil: f.perfil || 'OPERADOR',
                    foto_url: '',
                    is_transportadora: f.is_transportadora || false,
                    logo_url: f.logo_url || '',
                    vinculo: null,
                    senha_provisoria: f.senha_provisoria,
                    // NOVO: o app do celular usa isso pra saber se abre a
                    // tela de GESTORA (avisos de coleta) para esta pessoa.
                    funcionario_id: f.id,
                    recebe_avisos_app: f.recebe_avisos_app === true,
                });
            }

            user = await pool.query('SELECT * FROM embarcadores WHERE cpf_cnpj = $1 OR usuario_login = $1 ORDER BY id DESC LIMIT 1', [login]);
            role = 'embarcador';
        }

        if (user.rows.length === 0) return res.status(401).json({ error: 'Usuário não encontrado' });

        const dados = user.rows[0];

        const dbSenha = String(dados.senha_hash || '').trim();
        const reqSenha = String(senha || '').trim();
        const match = (reqSenha === dbSenha);

        if (match) {
            const emailDoUsuario = dados.email || dados.admin_email;
            // CORRIGIDO: motorista FUNCIONARIO é cadastrado direto pela
            // transportadora (que já valida CPF/RG dele) — nunca deveria
            // ficar travado esperando confirmação de um e-mail que
            // muitas vezes nem existe no cadastro. A trava de e-mail só
            // faz sentido pra quem se auto-cadastrou (motorista autônomo
            // ou embarcador comum).
            if (dados.email_verificado === false && dados.vinculo !== 'FUNCIONARIO') {
                return res.status(403).json({
                    error: 'EMAIL_NAO_VERIFICADO',
                    message: 'Confirme seu e-mail antes de fazer login. Enviamos um código de verificação no seu cadastro.',
                    email: emailDoUsuario,
                    role: role
                });
            }

            // NOVO: motorista TAC autônomo que desativou a própria conta
            // (ver /api/motorista/desativar-conta) não consegue mais
            // logar — precisa fazer um novo autocadastro com o mesmo CPF
            // pra reativar (ver /api/motorista/cadastro e
            // /api/motorista/reativar-conta).
            if (role === 'motorista' && dados.conta_desativada_em) {
                return res.status(403).json({
                    error: 'CONTA_DESATIVADA',
                    message: 'Esta conta foi desativada. Para voltar a usar o TACLOG, faça um novo cadastro com o mesmo CPF — vamos te oferecer reativar a conta antiga.'
                });
            }

            const fotoUrl = dados.foto_perfil_path || dados.foto_cnh_url || '';
            const isTransportadora = dados.is_transportadora || false;
            const logoUrl = dados.logo_url || '';
            const vinculo = dados.vinculo || 'AUTONOMO'; // só existe pra motorista; embarcador vem undefined -> 'AUTONOMO' não é usado nesse caso
            // NOVO: admin_nome (pessoa física responsável, só existe pra
            // embarcador) vai junto no token — usado pra registrar "quem
            // fez" quando é o próprio dono logando, não um funcionário.
            // NOVO: "perfil" (ADMIN/OPERADOR) — o titular (dono da conta)
            // é sempre ADMIN; pra motorista o campo não se aplica (fica
            // undefined, não vai no token nem na resposta).
            const origemLogin = normalizarOrigemLogin(origem, role);
            const token = jwt.sign({ id: dados.id, role: role, nome: dados.nome || dados.razao_social, usuario: dados.usuario_login, is_transportadora: isTransportadora, admin_nome: role === 'embarcador' ? dados.admin_nome : undefined, perfil: role === 'embarcador' ? 'ADMIN' : undefined }, JWT_SECRET);

            // NOVO: Log do Sistema — registra o login do titular ou do
            // motorista (TAC autônomo ou de frota/funcionário).
            if (role === 'embarcador') {
                registrarLogAtividade({
                    tipoUsuario: 'EMBARCADOR_TITULAR',
                    usuarioId: dados.id,
                    usuarioNome: dados.admin_nome || dados.razao_social,
                    perfil: 'ADMIN',
                    origem: origemLogin,
                    empresaId: dados.id,
                });
            } else {
                registrarLogAtividade({
                    tipoUsuario: vinculo === 'FUNCIONARIO' ? 'MOTORISTA_FUNCIONARIO' : 'MOTORISTA_TAC',
                    usuarioId: dados.id,
                    usuarioNome: dados.nome,
                    perfil: null,
                    origem: origemLogin,
                    empresaId: vinculo === 'FUNCIONARIO' ? dados.embarcador_empregador_id : null,
                    lat: latLogin,
                    lng: lngLogin,
                });
            }

            res.json({ token, motorista_id: dados.id, nome: dados.nome || dados.razao_social, role, perfil: role === 'embarcador' ? 'ADMIN' : null, foto_url: fotoUrl, is_transportadora: isTransportadora, logo_url: logoUrl, vinculo: role === 'motorista' ? vinculo : null });
        } else {
            res.status(401).json({ error: 'Senha incorreta' });
        }
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// FUNCIONÁRIOS DA TRANSPORTADORA — usuários cadastrados pelo administrador
// (o titular, quem loga direto com CNPJ) pra usar o sistema com CPF e
// senha próprios. Todo funcionário ATIVO tem o mesmo acesso que o
// administrador — não existe hierarquia de permissões ainda; a diferença
// é só que cada ação passa a registrar o nome de quem fez de verdade.
// =========================================================================

// 8 caracteres, sem 0/O/1/I (fácil de ditar por telefone sem confundir).
function gerarSenhaProvisoria() {
    const alfabeto = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let senha = '';
    for (let i = 0; i < 8; i++) senha += alfabeto[Math.floor(Math.random() * alfabeto.length)];
    return senha;
}

// Só o TITULAR da conta (quem logou direto com CNPJ) pode gerenciar
// funcionários — um funcionário logado não pode cadastrar outro.
function exigirTitular(req, res, next) {
    if (req.user.role !== 'embarcador' || req.user.funcionario_id) {
        return res.status(403).json({ error: 'Apenas o administrador da transportadora pode gerenciar funcionários.' });
    }
    next();
}

app.get('/api/embarcador/funcionarios', authenticateToken, exigirTitular, async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT id, nome, cpf, email, status, perfil, senha_provisoria, recebe_avisos_app, data_cadastro FROM funcionarios_embarcador WHERE embarcador_id = $1 ORDER BY nome ASC',
            [req.user.id]
        );
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/embarcador/funcionarios', authenticateToken, exigirTitular, async (req, res) => {
    const { nome, cpf, email, perfil, recebe_avisos_app } = req.body;
    try {
        if (!nome || !cpf) return res.status(400).json({ error: 'Nome e CPF são obrigatórios.' });
        const cpfLimpo = String(cpf).replace(/\D/g, '');
        if (cpfLimpo.length !== 11) return res.status(400).json({ error: 'CPF inválido.' });

        // NOVO: perfil de acesso — ADMIN (mesmo poder operacional do
        // titular) ou OPERADOR (não exclui motorista/caminhão/carreta nem
        // cancela carga já finalizada). OPERADOR é o padrão quando não
        // vem nada, pra sempre nascer com o acesso mais restrito.
        const perfilEscolhido = String(perfil || 'OPERADOR').toUpperCase();
        if (!['ADMIN', 'OPERADOR'].includes(perfilEscolhido)) {
            return res.status(400).json({ error: 'Perfil inválido — use ADMIN ou OPERADOR.' });
        }

        const existente = await pool.query('SELECT id FROM funcionarios_embarcador WHERE cpf = $1', [cpfLimpo]);
        if (existente.rows.length > 0) return res.status(400).json({ error: 'Já existe um funcionário cadastrado com esse CPF.' });

        // NOVO: CPF é ou de motorista (TAC autônomo ou motorista-funcionário
        // designado pela própria transportadora), ou de funcionário de
        // escritório — nunca os dois, pra não ter ambiguidade no login.
        // ATENÇÃO: diferente da trava do outro lado, aqui ainda não dá pra
        // filtrar por "motorista ainda ativo" — a tabela motoristas não
        // tem hoje um status de conta cancelada/desativada (o cadastro é
        // permanente, sem fluxo de "desisti de ser TAC"). Por enquanto,
        // QUALQUER CPF já cadastrado como motorista trava aqui,
        // mesmo que a pessoa tenha abandonado a conta. Se isso virar um
        // problema na prática, precisamos adicionar esse status em
        // motoristas também.
        const jaMotorista = await pool.query('SELECT id FROM motoristas WHERE cpf = $1', [cpfLimpo]);
        if (jaMotorista.rows.length > 0) {
            return res.status(400).json({ error: 'Este CPF já está cadastrado como motorista. Não é possível também cadastrá-lo como funcionário com o mesmo CPF.' });
        }

        const senhaProvisoria = gerarSenhaProvisoria();
        const result = await pool.query(
            `INSERT INTO funcionarios_embarcador (embarcador_id, nome, cpf, email, senha_hash, senha_provisoria, status, perfil, recebe_avisos_app)
             VALUES ($1, $2, $3, $4, $5, true, 'ATIVO', $6, $7)
             RETURNING id, nome, cpf, email, status, perfil, senha_provisoria, recebe_avisos_app, data_cadastro`,
            [req.user.id, nome, cpfLimpo, email || null, senhaProvisoria, perfilEscolhido, recebe_avisos_app === true]
        );
        // NOVO: a senha provisória só aparece UMA VEZ, nesta resposta —
        // não fica salva em nenhum lugar legível depois disso. Se o
        // administrador perder, precisa gerar outra em "Resetar senha".
        res.status(201).json({ ...result.rows[0], senha_provisoria_texto: senhaProvisoria });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/funcionarios/:id', authenticateToken, exigirTitular, async (req, res) => {
    const { id } = req.params;
    const { nome, email, status, perfil, recebe_avisos_app } = req.body;
    try {
        if (status && !['ATIVO', 'INATIVO', 'SUSPENSO'].includes(status)) {
            return res.status(400).json({ error: 'Status inválido.' });
        }
        // NOVO: o titular também pode trocar o perfil (ADMIN/OPERADOR) de
        // um funcionário já cadastrado.
        if (perfil && !['ADMIN', 'OPERADOR'].includes(String(perfil).toUpperCase())) {
            return res.status(400).json({ error: 'Perfil inválido — use ADMIN ou OPERADOR.' });
        }
        const result = await pool.query(
            `UPDATE funcionarios_embarcador
             SET nome = COALESCE($1, nome), email = COALESCE($2, email), status = COALESCE($3, status), perfil = COALESCE($4, perfil),
                 recebe_avisos_app = COALESCE($5, recebe_avisos_app)
             WHERE id = $6 AND embarcador_id = $7
             RETURNING id`,
            [nome || null, email || null, status || null, perfil ? String(perfil).toUpperCase() : null,
             typeof recebe_avisos_app === 'boolean' ? recebe_avisos_app : null, id, req.user.id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Funcionário não encontrado.' });
        res.json({ message: 'Funcionário atualizado!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/embarcador/funcionarios/:id/resetar-senha', authenticateToken, exigirTitular, async (req, res) => {
    const { id } = req.params;
    try {
        const senhaProvisoria = gerarSenhaProvisoria();
        const result = await pool.query(
            `UPDATE funcionarios_embarcador SET senha_hash = $1, senha_provisoria = true
             WHERE id = $2 AND embarcador_id = $3 RETURNING id`,
            [senhaProvisoria, id, req.user.id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Funcionário não encontrado.' });
        res.json({ senha_provisoria_texto: senhaProvisoria });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// NOVO: LOG DO SISTEMA — por enquanto só mostra os LOGINS (quem, quando,
// de onde) de todo mundo ligado a esta transportadora: o titular, os
// funcionários e os motoristas de frota (funcionário). Só administrador
// vê essa tela. Motorista TAC autônomo não aparece aqui porque não
// pertence a uma transportadora só — o login dele fica registrado no
// banco, mas essa listagem é por empresa.
// =========================================================================
// =========================================================================
// CLASSIFICAÇÃO DE MERCADO (tipos_veiculo / tipos_carroceria) — validação
// e ESPELHAMENTO nos campos antigos de texto.
//
// As telas agora mandam o CÓDIGO padronizado (ex.: 'BAU', 'SIDER',
// 'CARRETA'). Aqui o backend: (1) confere se o código existe e está ativo;
// (2) transforma '' em null (pra não quebrar a FK); (3) copia o NOME da
// carroceria pro campo antigo que o match de cargas usa hoje:
//     caminhão RIGIDO -> caminhoes.tipo_veiculo
//     carreta         -> carretas.tipo_carroceria
//     carga           -> cargas.tipo_veiculo_necessario (via c.tipo_veiculo)
// Assim o motor de match (view conjuntos_ativos) continua funcionando
// exatamente como antes, só que agora com a nomenclatura padronizada.
// Retorna uma mensagem de erro (string) ou null se estiver tudo certo.
// alvo: 'caminhao' | 'carreta' | 'carga'
// =========================================================================
async function resolverClassificacoes(c, alvo) {
    const campoVeiculo = alvo === 'carga' ? 'classificacao_veiculo_necessaria' : 'classificacao_veiculo';
    const campoCarroceria = alvo === 'carga' ? 'classificacao_carroceria_necessaria' : 'classificacao_carroceria';

    for (const campo of [campoVeiculo, campoCarroceria]) {
        if (c[campo] === '' || c[campo] === 'null') c[campo] = null;
    }

    if (c[campoVeiculo]) {
        const r = await pool.query('SELECT 1 FROM tipos_veiculo WHERE codigo = $1 AND ativo = TRUE', [c[campoVeiculo]]);
        if (r.rows.length === 0) return 'Tipo de veículo inválido: ' + c[campoVeiculo];
    }

    if (c[campoCarroceria]) {
        const r = await pool.query('SELECT nome FROM tipos_carroceria WHERE codigo = $1 AND ativo = TRUE', [c[campoCarroceria]]);
        if (r.rows.length === 0) return 'Tipo de carroceria inválido: ' + c[campoCarroceria];
        const nome = r.rows[0].nome;

        if (alvo === 'carreta') {
            c.tipo_carroceria = nome;
        } else if (alvo === 'carga') {
            c.tipo_veiculo = nome;
        } else if (alvo === 'caminhao') {
            if (c.tipo_unidade_tratora === 'CAVALO_MECANICO') {
                // Cavalo mecânico não tem carroceria própria: quem define é a carreta acoplada.
                c[campoCarroceria] = null;
            } else {
                c.tipo_veiculo = nome;
            }
        }
    }
    return null;
}

// =========================================================================
// TIPOS DE VEÍCULO / CARROCERIA (nomenclatura de mercado)
// Alimentam os selects agrupados nas telas de cadastro de caminhão/carreta
// e de publicação de carga. Qualquer usuário logado pode consultar.
// Retorno: [{ grupo: 'PESADO', itens: [{ codigo, nome }, ...] }, ...]
// =========================================================================
function agruparTiposPorGrupo(rows, ordemGrupos) {
    const mapa = {};
    rows.forEach(r => {
        if (!mapa[r.grupo]) mapa[r.grupo] = [];
        mapa[r.grupo].push({ codigo: r.codigo, nome: r.nome });
    });
    return ordemGrupos.filter(g => mapa[g]).map(g => ({ grupo: g, itens: mapa[g] }));
}

app.get('/api/tipos-veiculo', authenticateToken, async (req, res) => {
    try {
        const r = await pool.query(
            `SELECT codigo, nome, grupo FROM tipos_veiculo WHERE ativo = TRUE ORDER BY grupo, ordem_exibicao, nome`
        );
        res.json(agruparTiposPorGrupo(r.rows, ['PESADO', 'MEDIO', 'LEVE']));
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/tipos-carroceria', authenticateToken, async (req, res) => {
    try {
        const r = await pool.query(
            `SELECT codigo, nome, grupo FROM tipos_carroceria WHERE ativo = TRUE ORDER BY grupo, ordem_exibicao, nome`
        );
        res.json(agruparTiposPorGrupo(r.rows, ['ABERTA', 'FECHADA', 'ESPECIAL']));
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/embarcador/logs-atividade', authenticateToken, exigirPerfilAdmin, async (req, res) => {
    try {
        const limite = Math.min(parseInt(req.query.limite) || 100, 500);
        const result = await pool.query(
            `SELECT id, data_hora, tipo_evento, tipo_usuario, usuario_id, usuario_nome, perfil, origem, lat, lng
             FROM logs_atividade
             WHERE empresa_id = $1
             ORDER BY data_hora DESC
             LIMIT $2`,
            [req.user.id, limite]
        );
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Troca de senha do próprio funcionário — chamada logo depois do primeiro
// login (quando senha_provisoria = true, o authenticateToken só deixa
// passar nesta rota), mas também serve pra trocar a senha por vontade
// própria depois.
app.post('/api/funcionario/trocar-senha', authenticateToken, async (req, res) => {
    const { nova_senha, confirmar_senha } = req.body;
    if (!req.user.funcionario_id) {
        return res.status(400).json({ error: 'Esta rota é só para funcionários.' });
    }
    try {
        if (!nova_senha || String(nova_senha).trim().length < 6) {
            return res.status(400).json({ error: 'A nova senha precisa ter pelo menos 6 caracteres.' });
        }
        if (nova_senha !== confirmar_senha) {
            return res.status(400).json({ error: 'As senhas não coincidem.' });
        }
        await pool.query(
            'UPDATE funcionarios_embarcador SET senha_hash = $1, senha_provisoria = false WHERE id = $2',
            [String(nova_senha).trim(), req.user.funcionario_id]
        );
        // NOVO: devolve um token novo já sem a marca de senha provisória
        // — o token antigo (do login) ficaria bloqueado pra sempre sem
        // isso, já que o JWT não se atualiza sozinho quando o banco muda.
        const { iat, exp, ...claimsAtuais } = req.user;
        const novoToken = jwt.sign({ ...claimsAtuais, senha_provisoria: false }, JWT_SECRET);
        res.json({ message: 'Senha atualizada!', token: novoToken });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/embarcador/cadastro', async (req, res) => {
    const e = req.body;
    try {
        if (!e.senha) throw new Error("Senha vazia!");
        
        const senhaHash = String(e.senha).trim(); 
        
        const check = await pool.query('SELECT id FROM embarcadores WHERE cpf_cnpj = $1', [e.cpf_cnpj]);
        if (check.rows.length > 0) return res.status(400).json({ error: 'CNPJ já cadastrado.' });

        const codigoVerificacao = gerarCodigoVerificacao();

        const sql = `
            INSERT INTO embarcadores (
                razao_social, nome_fantasia, cpf_cnpj, atividade_principal, tipo_entidade,
                inscricao_estadual, telefone_empresa, email_empresa, site, rntrc_transportadora,
                cep, logradouro, numero, complemento, bairro, cidade, uf, pais,
                admin_nome, admin_cargo, admin_fone, admin_email, usuario_login, senha_hash,
                pub_responsavel, pub_fone, pub_celular, pub_email,
                fin_responsavel, fin_cargo, fin_fone, fin_celular, fin_email,
                exp_responsavel, exp_cargo, exp_fone, exp_email,
                sac_responsavel, sac_cargo, sac_fone, sac_email,
                meio_pagamento_pref, verificar_motoristas, is_transportadora,
                codigo_verificacao, email_verificado
            ) VALUES (
                $1, $2, $3, $4, $5,
                $6, $7, $8, $9, $10,
                $11, $12, $13, $14, $15, $16, $17, $18,
                $19, $20, $21, $22, $23, $24,
                $25, $26, $27, $28,
                $29, $30, $31, $32, $33,
                $34, $35, $36, $37,
                $38, $39, $40, $41,
                $42, $43, $44,
                $45, false
            ) RETURNING id`;
            
        const loginUser = e.admin_email; 
        const values = [
            e.razao_social, e.nome_fantasia, e.cpf_cnpj, e.atividade_principal, 'JURIDICA',
            e.inscricao_estadual || null, e.telefone_empresa || null, e.email_empresa || null, e.site || null, e.rntrc_transportadora || null,
            e.cep, e.logradouro, e.numero, e.complemento, e.bairro, e.cidade, e.uf, 'Brasil',
            e.admin_nome, e.admin_cargo, e.admin_fone, e.admin_email, loginUser, senhaHash,
            e.pub_responsavel, e.pub_fone, e.pub_celular || null, e.pub_email,
            e.fin_responsavel, e.fin_cargo, e.fin_fone, e.fin_celular || null, e.fin_email,
            e.exp_responsavel, e.exp_cargo, e.exp_fone, e.exp_email,
            e.sac_responsavel, e.sac_cargo, e.sac_fone, e.sac_email,
            e.meio_pagamento, e.verificar_motoristas, !!e.is_transportadora,
            codigoVerificacao
        ];
        
        await pool.query(sql, values);

        try {
            await enviarEmailVerificacao(e.admin_email, e.admin_nome || e.razao_social, codigoVerificacao);
        } catch (mailErr) {
            console.error('Erro ao enviar e-mail de verificação (embarcador):', mailErr.message);
        }

        res.status(201).json({ message: 'Empresa cadastrada com sucesso! Verifique seu e-mail para ativar a conta.', email: e.admin_email });
    } catch (err) {
        console.error(err);
        res.status(500).json({ error: 'Erro ao cadastrar empresa: ' + err.message });
    }
});

app.post('/api/motorista/cadastro', upload.none(), async (req, res) => {
    const m = req.body;
    const client = await pool.connect();
    try {
        await client.query('BEGIN');

        // NOVO: CPF é ou de um TAC autônomo, ou de um funcionário de
        // transportadora — nunca os dois AO MESMO TEMPO. Só trava se o
        // funcionário estiver ATIVO ou SUSPENSO (ainda vinculado àquela
        // empresa) — se estiver INATIVO (ex.: saiu da empresa e virou TAC
        // por conta própria), o cadastro fica liberado. O registro antigo
        // em funcionarios_embarcador continua no banco do jeito que
        // estava, intacto, só pra histórico/auditoria de quando ele
        // trabalhou lá.
        const cpfLimpoCheck = String(m.cpf || '').replace(/\D/g, '');
        const jaFuncionario = await client.query(
            "SELECT id FROM funcionarios_embarcador WHERE cpf = $1 AND status IN ('ATIVO', 'SUSPENSO')",
            [cpfLimpoCheck]
        );
        if (jaFuncionario.rows.length > 0) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: 'Este CPF está cadastrado como funcionário ATIVO de uma transportadora. Não é possível também se cadastrar como motorista autônomo (TAC) enquanto esse vínculo estiver ativo.' });
        }

        // NOVO: CPF já cadastrado como motorista — se a conta estiver
        // desativada (o próprio motorista desativou, ver
        // /api/motorista/desativar-conta), não é um erro comum de "CPF
        // duplicado": avisa o front que existe uma conta pra reativar, em
        // vez de criar um cadastro novo e duplicado.
        const existenteMotorista = await client.query(
            'SELECT id, conta_desativada_em FROM motoristas WHERE cpf = $1',
            [cpfLimpoCheck]
        );
        if (existenteMotorista.rows.length > 0) {
            await client.query('ROLLBACK');
            if (existenteMotorista.rows[0].conta_desativada_em) {
                return res.status(409).json({
                    error: 'CONTA_DESATIVADA_ENCONTRADA',
                    message: 'Encontramos uma conta TACLOG desativada com esse CPF. Deseja reativá-la com os dados que você preencheu agora?'
                });
            }
            return res.status(400).json({ error: 'CPF já cadastrado no sistema.' });
        }

        const hash = String(m.senha).trim();
        const codigoVerificacao = gerarCodigoVerificacao();

        const sqlMot = `
            INSERT INTO motoristas 
            (nome, cpf, email, senha_hash, telefone_celular, rntrc, pis, status_cadastro, codigo_verificacao, email_verificado) 
            VALUES ($1, $2, $3, $4, $5, $6, $7, 'PENDENTE', $8, false) 
            RETURNING id
        `;
        
        const cpfLimpo = m.cpf.replace(/\D/g, '');
        const resMot = await client.query(sqlMot, [m.nome, cpfLimpo, m.email, hash, m.telefone_celular, m.rntrc, m.pis, codigoVerificacao]);
        const motoristaId = resMot.rows[0].id;
        
        if (m.placa && m.placa.trim() !== '') {
            const sqlCam = `
                INSERT INTO caminhoes (
                    proprietario_id, placa, renavam, marca, modelo, 
                    tipo_veiculo, classificacao_carroceria, tara_kg, peso_carga_kg, status_uso
                ) VALUES ($1, $2, $3, $4, $5, $6::varchar,
                    (SELECT codigo FROM tipos_carroceria WHERE nome = $6::varchar LIMIT 1),
                    $7, $8, 'PARADO')
            `;
            await client.query(sqlCam, [motoristaId, m.placa, m.renavam, m.marca, m.modelo, m.tipo_carroceria, m.tara || 0, m.lotacao_kg || 0]);
            await client.query('UPDATE motoristas SET possui_caminhao = TRUE WHERE id = $1', [motoristaId]);
        }
        await client.query('COMMIT');

        try {
            await enviarEmailVerificacao(m.email, m.nome, codigoVerificacao);
        } catch (mailErr) {
            console.error('Erro ao enviar e-mail de verificação (motorista):', mailErr.message);
        }

        res.status(201).json({ message: 'Bem-vindo ao TACLOG! Verifique seu e-mail para ativar a conta.', email: m.email });
    } catch (err) {
        await client.query('ROLLBACK');
        console.error(err);
        if (err.code === '23505') {
            return res.status(400).json({ error: 'CPF ou Placa já cadastrados no sistema.' });
        }
        res.status(500).json({ error: 'Erro ao salvar cadastro.' });
    } finally {
        client.release();
    }
});

// =========================================================================
// REATIVAÇÃO DE CONTA — motorista que desativou a própria conta (ver
// /api/motorista/desativar-conta) e faz um novo autocadastro com o
// mesmo CPF. Em vez de criar um registro novo, atualiza o registro
// antigo (mantém o mesmo id — e portanto o histórico de cargas/coletas
// já ligado a ele) com os dados que a pessoa preencheu agora, e exige
// verificação de e-mail de novo: como o sistema não tem um fluxo de
// "esqueci minha senha", essa verificação também serve como prova de
// que é o dono do e-mail cadastrado tentando reativar — não só alguém
// que sabe o CPF dele.
//
// Os caminhões/carretas antigos (marcados inativos na desativação)
// continuam inativos mesmo depois da conta reativada — podem ter sido
// vendidos nesse meio tempo. Se o motorista informar uma placa nesse
// novo cadastro, ela entra como veículo NOVO.
// =========================================================================
app.post('/api/motorista/reativar-conta', upload.none(), async (req, res) => {
    const m = req.body;
    try {
        const cpfLimpo = String(m.cpf || '').replace(/\D/g, '');
        const existente = await pool.query(
            'SELECT id FROM motoristas WHERE cpf = $1 AND conta_desativada_em IS NOT NULL',
            [cpfLimpo]
        );
        if (existente.rows.length === 0) {
            return res.status(404).json({ error: 'Nenhuma conta desativada encontrada com esse CPF.' });
        }
        const motoristaId = existente.rows[0].id;
        const codigoVerificacao = gerarCodigoVerificacao();
        const hash = String(m.senha).trim();

        await pool.query(
            `UPDATE motoristas SET
                nome = $1, email = $2, senha_hash = $3, telefone_celular = $4,
                rntrc = $5, pis = $6, email_verificado = false, codigo_verificacao = $7
             WHERE id = $8`,
            [m.nome, m.email, hash, m.telefone_celular, m.rntrc, m.pis, codigoVerificacao, motoristaId]
        );

        if (m.placa && m.placa.trim() !== '') {
            await pool.query(
                `INSERT INTO caminhoes (proprietario_id, placa, renavam, marca, modelo, tipo_veiculo, classificacao_carroceria, tara_kg, peso_carga_kg, status_uso, ativo)
                 VALUES ($1, $2, $3, $4, $5, $6::varchar,
                    (SELECT codigo FROM tipos_carroceria WHERE nome = $6::varchar LIMIT 1),
                    $7, $8, 'PARADO', true)`,
                [motoristaId, m.placa, m.renavam, m.marca, m.modelo, m.tipo_carroceria, m.tara || 0, m.lotacao_kg || 0]
            );
            await pool.query('UPDATE motoristas SET possui_caminhao = TRUE WHERE id = $1', [motoristaId]);
        }

        try {
            await enviarEmailVerificacao(m.email, m.nome, codigoVerificacao);
        } catch (mailErr) {
            console.error('Erro ao enviar e-mail de verificação (reativação):', mailErr.message);
        }

        res.status(200).json({ message: 'Pedido de reativação enviado! Verifique seu e-mail para confirmar e reativar sua conta.', email: m.email });
    } catch (e) {
        console.error(e);
        if (e.code === '23505') {
            return res.status(400).json({ error: 'Placa já cadastrada no sistema.' });
        }
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// DESATIVAÇÃO DE CONTA — o próprio motorista TAC autônomo desativa a
// conta dele (não é um admin fazendo isso por ele). A conta some do ar
// (login para de funcionar), mas nada é apagado — fica tudo no banco
// pra histórico. Os caminhões e carretas dele são marcados como
// inativos: se ele saiu da plataforma vendendo os veículos, isso evita
// que um caminhão que já não é mais dele continue aparecendo como
// disponível, caso o comprador também use o TACLOG.
//
// Pra reativar, é só fazer um novo autocadastro com o mesmo CPF (ver
// /api/motorista/cadastro e /api/motorista/reativar-conta acima) — os
// veículos antigos continuam inativos de propósito, mesmo depois de
// reativada.
// =========================================================================
app.post('/api/motorista/desativar-conta', authenticateToken, async (req, res) => {
    if (req.user.role !== 'motorista') {
        return res.status(403).json({ error: 'Esta ação é só para motoristas TAC autônomos.' });
    }
    const motoristaId = req.user.id;
    const client = await pool.connect();
    try {
        await client.query('BEGIN');

        const emViagem = await client.query(
            `SELECT id FROM cargas WHERE motorista_id = $1 AND status IN ('EM_ANDAMENTO', 'COLETADA')`,
            [motoristaId]
        );
        if (emViagem.rows.length > 0) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: 'Você está com uma carga em andamento — não é possível desativar a conta agora.' });
        }

        await client.query('UPDATE motoristas SET conta_desativada_em = NOW() WHERE id = $1', [motoristaId]);
        await client.query('UPDATE caminhoes SET ativo = FALSE WHERE proprietario_id = $1', [motoristaId]);
        await client.query('UPDATE carretas SET ativo = FALSE WHERE proprietario_id = $1', [motoristaId]);

        await client.query('COMMIT');
        res.json({ message: 'Conta desativada. Seus caminhões e carretas foram marcados como inativos.' });
    } catch (e) {
        await client.query('ROLLBACK');
        console.error(e);
        res.status(500).json({ error: e.message });
    } finally {
        client.release();
    }
});

// =========================================================================
// VERIFICAÇÃO DE E-MAIL — ROTAS
// =========================================================================
app.post('/api/motorista/verificar', async (req, res) => {
    const { email, codigo } = req.body;
    if (!email || !codigo) return res.status(400).json({ error: 'E-mail e código são obrigatórios.' });
    try {
        const result = await pool.query(
            'SELECT id, codigo_verificacao, email_verificado FROM motoristas WHERE email = $1 ORDER BY id DESC LIMIT 1',
            [email]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'E-mail não encontrado.' });

        const motorista = result.rows[0];
        if (motorista.email_verificado) return res.status(200).json({ message: 'E-mail já verificado.' });

        if (String(motorista.codigo_verificacao || '').trim() !== String(codigo).trim()) {
            return res.status(400).json({ error: 'Código incorreto.' });
        }

        // NOVO: também limpa conta_desativada_em — se essa verificação
        // era de uma reativação (ver /api/motorista/reativar-conta), é
        // isso que efetivamente reativa a conta. Pra um cadastro novo
        // normal, esse campo já é NULL, então não muda nada.
        await pool.query('UPDATE motoristas SET email_verificado = true, codigo_verificacao = NULL, conta_desativada_em = NULL WHERE id = $1', [motorista.id]);
        res.status(200).json({ message: 'E-mail verificado com sucesso!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/motorista/reenviar-codigo', async (req, res) => {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'E-mail é obrigatório.' });
    try {
        const result = await pool.query('SELECT id, nome, email_verificado FROM motoristas WHERE email = $1 ORDER BY id DESC LIMIT 1', [email]);
        if (result.rows.length === 0) return res.status(404).json({ error: 'E-mail não encontrado.' });

        const motorista = result.rows[0];
        if (motorista.email_verificado) return res.status(200).json({ message: 'E-mail já verificado.' });

        const novoCodigo = gerarCodigoVerificacao();
        await pool.query('UPDATE motoristas SET codigo_verificacao = $1 WHERE id = $2', [novoCodigo, motorista.id]);
        await enviarEmailVerificacao(email, motorista.nome, novoCodigo);
        res.json({ message: 'Novo código enviado!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/embarcador/verificar', async (req, res) => {
    const { email, codigo } = req.body;
    if (!email || !codigo) return res.status(400).json({ error: 'E-mail e código são obrigatórios.' });
    try {
        const result = await pool.query(
            'SELECT id, codigo_verificacao, email_verificado FROM embarcadores WHERE admin_email = $1 ORDER BY id DESC LIMIT 1',
            [email]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'E-mail não encontrado.' });

        const emb = result.rows[0];
        if (emb.email_verificado) return res.status(200).json({ message: 'E-mail já verificado.' });

        if (String(emb.codigo_verificacao || '').trim() !== String(codigo).trim()) {
            return res.status(400).json({ error: 'Código incorreto.' });
        }

        await pool.query('UPDATE embarcadores SET email_verificado = true, codigo_verificacao = NULL WHERE id = $1', [emb.id]);
        res.status(200).json({ message: 'E-mail verificado com sucesso!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/embarcador/reenviar-codigo', async (req, res) => {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'E-mail é obrigatório.' });
    try {
        const result = await pool.query('SELECT id, admin_nome, razao_social, email_verificado FROM embarcadores WHERE admin_email = $1 ORDER BY id DESC LIMIT 1', [email]);
        if (result.rows.length === 0) return res.status(404).json({ error: 'E-mail não encontrado.' });

        const emb = result.rows[0];
        if (emb.email_verificado) return res.status(200).json({ message: 'E-mail já verificado.' });

        const novoCodigo = gerarCodigoVerificacao();
        await pool.query('UPDATE embarcadores SET codigo_verificacao = $1 WHERE id = $2', [novoCodigo, emb.id]);
        await enviarEmailVerificacao(email, emb.admin_nome || emb.razao_social, novoCodigo);
        res.json({ message: 'Novo código enviado!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// --- ROTAS GESTÃO DE CARGAS ---
app.get('/api/cargas/listar', authenticateToken, async (req, res) => {
    try {
        let sql = '';
        let params = [];
        
        const baseQuery = `
            SELECT c.*, 
                   m.nome as motorista_nome, 
                   m.foto_perfil_path as motorista_foto, 
                   m.foto_cnh_url as motorista_cnh_foto,
                   cam.placa as caminhao_placa,
                   camd.placa as caminhao_designado_placa
            FROM cargas c
            LEFT JOIN motoristas m ON c.motorista_id = m.id
            LEFT JOIN caminhoes cam ON m.caminhao_ativo_id = cam.id
            LEFT JOIN caminhoes camd ON c.caminhao_designado_id = camd.id
        `;

        if (req.user.usuario === 'admin_taclog') {
            sql = `${baseQuery} ORDER BY c.id DESC`;
        } else {
            sql = `${baseQuery} WHERE c.embarcador_id = $1 ORDER BY c.id DESC`;
            params = [req.user.id];
        }
        const result = await pool.query(sql, params);
        res.json(result.rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// CRIAÇÃO DE CARGA — COM SUPORTE A AGENDAMENTO DE COLETA E PREFERÊNCIA DE
// FROTA PRÓPRIA. Se preferencia_frota_propria = true, a carga nasce com
// frota_tentativa_realizada = false, o que TRAVA o matchmaking normal (TAC
// autônomo) até que o scheduler verificarPreferenciaFrota() tente achar um
// motorista da frota própria primeiro (ver função no final do arquivo).
// =========================================================================
app.post('/api/cargas/nova', authenticateToken, async (req, res) => {
    const c = req.body;
    const dono_id = req.user.id;
    try {
        let status = 'DISPONIVEL';
        let dataHoraDisparo = null;
        let disparoRealizado = true;

        if (c.data_coleta && c.hora_coleta) {
            const momentoColeta = new Date(`${c.data_coleta}T${c.hora_coleta}:00`);
            const antecedenciaMin = parseInt(c.tempo_antecedencia_minutos) || 0;
            dataHoraDisparo = new Date(momentoColeta.getTime() - antecedenciaMin * 60000);

            if (dataHoraDisparo <= new Date()) {
                status = 'DISPONIVEL';
                disparoRealizado = true;
            } else {
                status = 'AGENDADA';
                disparoRealizado = false;
            }
        }

        // NOVO: escolha manual de caminhão da frota. Se vier preenchido,
        // valida que o caminhão é mesmo da frota deste embarcador e que,
        // se for Cavalo Mecânico, já está com uma carreta acoplada agora
        // — nunca deixa designar um cavalo mecânico "pelado".
        let caminhaoDesignadoId = null;
        if (c.caminhao_designado_id) {
            const caminhaoCheck = await pool.query(`
                SELECT cam.id, cam.tipo_unidade_tratora, a.carreta_id
                FROM caminhoes cam
                LEFT JOIN acoplamentos a ON a.caminhao_id = cam.id AND a.data_fim IS NULL
                WHERE cam.id = $1 AND cam.embarcador_proprietario_id = $2
            `, [c.caminhao_designado_id, dono_id]);

            if (caminhaoCheck.rows.length === 0) {
                return res.status(400).json({ error: 'Caminhão designado não pertence à sua frota.' });
            }
            const cam = caminhaoCheck.rows[0];
            if (cam.tipo_unidade_tratora === 'CAVALO_MECANICO' && !cam.carreta_id) {
                return res.status(400).json({ error: 'Este caminhão é um Cavalo Mecânico sem carreta acoplada no momento. Acople uma carreta antes de designá-lo para uma carga.' });
            }
            caminhaoDesignadoId = cam.id;
        }

        // Designar um caminhão específico usa a mesma esteira de "preferência
        // de frota" já existente (o scheduler verificarPreferenciaFrota cuida
        // de enviar a oferta certa) — só que, quando caminhao_designado_id
        // está preenchido, ele pula a busca por proximidade e vai direto
        // nesse caminhão (ver função no final do arquivo).
        const erroClassificacao = await resolverClassificacoes(c, 'carga');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });

        const temPreferenciaFrota = c.preferencia_frota_propria === true || !!caminhaoDesignadoId;
        const frotaTentativaRealizada = !temPreferenciaFrota; // se tem preferência, ainda NÃO tentamos a frota

        const sql = `
            INSERT INTO cargas (
                embarcador_id, descricao, valor_frete, valor_pedagio, peso_kg, chave_nfe, tipo_veiculo_necessario,
                col_rua, col_numero, col_cidade, col_uf, col_cep, lat_coleta, lng_coleta,
                ent_rua, ent_numero, ent_cidade, ent_uf, ent_cep, lat_entrega, lng_entrega,
                distancia_km, status,
                data_coleta, hora_coleta, tempo_antecedencia_minutos, data_hora_disparo_prevista, disparo_realizado,
                preferencia_frota_propria, frota_tentativa_realizada, caminhao_designado_id,
                criado_por_id, criado_por_nome,
                classificacao_veiculo_necessaria, classificacao_carroceria_necessaria
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21,
                $22, $23, $24, $25, $26, $27, $28, $29, $30, $31, $32, $33, $34, $35
            ) RETURNING id
        `;
        await pool.query(sql, [
            dono_id, c.descricao, c.valor, c.pedagio || 0, c.peso, c.chave_nfe, c.tipo_veiculo,
            c.col_rua, c.col_numero, c.col_cid, c.col_uf, c.col_cep, c.lat_coleta, c.lng_coleta,
            c.ent_rua, c.ent_numero, c.ent_cid, c.ent_uf, c.ent_cep, c.lat_entrega || null, c.lng_entrega || null,
            c.distancia_km || 0, status,
            c.data_coleta || null, c.hora_coleta || null, c.tempo_antecedencia_minutos || 0, dataHoraDisparo, disparoRealizado,
            temPreferenciaFrota,
            frotaTentativaRealizada,
            caminhaoDesignadoId,
            req.user.id, nomeDoAtor(req),
            c.classificacao_veiculo_necessaria || null, c.classificacao_carroceria_necessaria || null
        ]);

        if (caminhaoDesignadoId) {
            const dataFmt = c.data_coleta || '';
            const horaFmt = c.hora_coleta ? ` às ${c.hora_coleta}` : '';
            await notificarCaminhaoDesignadoAgora(
                caminhaoDesignadoId,
                `Nova carga agendada para ${dataFmt}${horaFmt} — ${c.descricao || ''} (${c.col_cid}/${c.col_uf}).`
            );
        }

        res.status(201).json({
            message: status === 'AGENDADA'
                ? 'Carga agendada! A oferta será enviada aos motoristas próximo ao horário da coleta.'
                : 'Carga Criada!'
        });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// EDIÇÃO DE CARGA — permite editar cargas DISPONIVEL ou AGENDADA, recalcula
// o horário de disparo e também reseta a tentativa de frota própria se a
// preferência foi alterada na edição.
// =========================================================================
app.put('/api/cargas/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const dono_id = req.user.id;
    try {
        const check = await pool.query('SELECT status, caminhao_designado_id FROM cargas WHERE id = $1 AND embarcador_id = $2', [id, dono_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Carga não encontrada ou sem permissão.' });

        if (!['DISPONIVEL', 'AGENDADA'].includes(check.rows[0].status)) {
            return res.status(400).json({ error: 'Só é possível editar cargas com status DISPONÍVEL ou AGENDADA.' });
        }
        const caminhaoAnteriorId = check.rows[0].caminhao_designado_id;

        let status = 'DISPONIVEL';
        let dataHoraDisparo = null;
        let disparoRealizado = true;

        if (c.data_coleta && c.hora_coleta) {
            const momentoColeta = new Date(`${c.data_coleta}T${c.hora_coleta}:00`);
            const antecedenciaMin = parseInt(c.tempo_antecedencia_minutos) || 0;
            dataHoraDisparo = new Date(momentoColeta.getTime() - antecedenciaMin * 60000);

            if (dataHoraDisparo <= new Date()) {
                status = 'DISPONIVEL';
                disparoRealizado = true;
            } else {
                status = 'AGENDADA';
                disparoRealizado = false;
            }
        }

        // Mesma validação da criação: caminhão designado precisa ser da
        // frota deste embarcador e, se Cavalo Mecânico, estar com carreta
        // acoplada agora.
        let caminhaoDesignadoId = null;
        if (c.caminhao_designado_id) {
            const caminhaoCheck = await pool.query(`
                SELECT cam.id, cam.tipo_unidade_tratora, a.carreta_id
                FROM caminhoes cam
                LEFT JOIN acoplamentos a ON a.caminhao_id = cam.id AND a.data_fim IS NULL
                WHERE cam.id = $1 AND cam.embarcador_proprietario_id = $2
            `, [c.caminhao_designado_id, dono_id]);

            if (caminhaoCheck.rows.length === 0) {
                return res.status(400).json({ error: 'Caminhão designado não pertence à sua frota.' });
            }
            const cam = caminhaoCheck.rows[0];
            if (cam.tipo_unidade_tratora === 'CAVALO_MECANICO' && !cam.carreta_id) {
                return res.status(400).json({ error: 'Este caminhão é um Cavalo Mecânico sem carreta acoplada no momento. Acople uma carreta antes de designá-lo para uma carga.' });
            }
            caminhaoDesignadoId = cam.id;
        }

        const erroClassificacao = await resolverClassificacoes(c, 'carga');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });

        const temPreferenciaFrota = c.preferencia_frota_propria === true || !!caminhaoDesignadoId;
        const frotaTentativaRealizada = !temPreferenciaFrota;

        const sql = `
            UPDATE cargas SET
                descricao = $1, valor_frete = $2, valor_pedagio = $3, peso_kg = $4, chave_nfe = $5, tipo_veiculo_necessario = $6,
                col_rua = $7, col_numero = $8, col_cidade = $9, col_uf = $10, col_cep = $11,
                ent_rua = $12, ent_numero = $13, ent_cidade = $14, ent_uf = $15, ent_cep = $16,
                lat_coleta = $17, lng_coleta = $18,
                lat_entrega = $19, lng_entrega = $20, distancia_km = $21,
                data_coleta = $22, hora_coleta = $23, tempo_antecedencia_minutos = $24,
                data_hora_disparo_prevista = $25, disparo_realizado = $26, status = $27,
                preferencia_frota_propria = $28, frota_tentativa_realizada = $29, caminhao_designado_id = $30,
                editado_por_nome = $31, editado_em = NOW(),
                classificacao_veiculo_necessaria = $34, classificacao_carroceria_necessaria = $35
            WHERE id = $32 AND embarcador_id = $33
        `;
        await pool.query(sql, [
            c.descricao, c.valor, c.pedagio || 0, c.peso, c.chave_nfe, c.tipo_veiculo,
            c.col_rua, c.col_numero, c.col_cid, c.col_uf, c.col_cep,
            c.ent_rua, c.ent_numero, c.ent_cid, c.ent_uf, c.ent_cep,
            c.lat_coleta, c.lng_coleta,
            c.lat_entrega || null, c.lng_entrega || null, c.distancia_km || 0,
            c.data_coleta || null, c.hora_coleta || null, c.tempo_antecedencia_minutos || 0,
            dataHoraDisparo, disparoRealizado, status,
            temPreferenciaFrota,
            frotaTentativaRealizada,
            caminhaoDesignadoId,
            nomeDoAtor(req),
            id, dono_id,
            c.classificacao_veiculo_necessaria || null, c.classificacao_carroceria_necessaria || null
        ]);
        res.status(200).json({ message: 'Carga atualizada com sucesso!' });

        if (caminhaoDesignadoId && caminhaoDesignadoId != caminhaoAnteriorId) {
            const dataFmt = c.data_coleta || '';
            const horaFmt = c.hora_coleta ? ` às ${c.hora_coleta}` : '';
            notificarCaminhaoDesignadoAgora(
                caminhaoDesignadoId,
                `Carga agendada para ${dataFmt}${horaFmt} — ${c.descricao || ''} (${c.col_cid}/${c.col_uf}).`
            );
        }
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// REAGENDAR — troca só data/hora/antecedência de uma carga do Mercado,
// sem mexer em mais nada (a rota PUT completa exige o payload inteiro,
// e reenviaria tudo — essa aqui é só pro "editar rapidinho a data/hora"
// da tela de Agendamentos).
// =========================================================================
app.put('/api/cargas/:id/reagendar', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const { data_coleta, hora_coleta, tempo_antecedencia_minutos } = req.body;
    const dono_id = req.user.id;
    try {
        const check = await pool.query('SELECT status, caminhao_designado_id, descricao, col_cidade, col_uf FROM cargas WHERE id = $1 AND embarcador_id = $2', [id, dono_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Carga não encontrada ou sem permissão.' });
        if (!['DISPONIVEL', 'AGENDADA'].includes(check.rows[0].status)) {
            return res.status(400).json({ error: 'Só é possível reagendar cargas com status DISPONÍVEL ou AGENDADA.' });
        }
        if (!data_coleta) return res.status(400).json({ error: 'Informe a data da coleta.' });

        let status = 'DISPONIVEL';
        let dataHoraDisparo = null;
        let disparoRealizado = true;

        if (data_coleta && hora_coleta) {
            const momentoColeta = new Date(`${data_coleta}T${hora_coleta}:00`);
            const antecedenciaMin = parseInt(tempo_antecedencia_minutos) || 0;
            dataHoraDisparo = new Date(momentoColeta.getTime() - antecedenciaMin * 60000);

            if (dataHoraDisparo <= new Date()) {
                status = 'DISPONIVEL';
                disparoRealizado = true;
            } else {
                status = 'AGENDADA';
                disparoRealizado = false;
            }
        }

        await pool.query(
            `UPDATE cargas SET data_coleta = $1, hora_coleta = $2, tempo_antecedencia_minutos = $3,
                                data_hora_disparo_prevista = $4, disparo_realizado = $5, status = $6,
                                editado_por_nome = $7, editado_em = NOW()
             WHERE id = $8 AND embarcador_id = $9`,
            [data_coleta, hora_coleta || null, tempo_antecedencia_minutos || 0, dataHoraDisparo, disparoRealizado, status, nomeDoAtor(req), id, dono_id]
        );

        // NOVO: se essa carga já tinha um caminhão designado, ele precisa
        // ser avisado de novo — a data/hora que ele viu antes não vale
        // mais.
        if (check.rows[0].caminhao_designado_id) {
            const horaFmt = hora_coleta ? ` às ${hora_coleta}` : '';
            await notificarCaminhaoDesignadoAgora(
                check.rows[0].caminhao_designado_id,
                `Carga reagendada — agora em ${data_coleta}${horaFmt} — ${check.rows[0].descricao || ''} (${check.rows[0].col_cidade}/${check.rows[0].col_uf}).`
            );
        }

        res.json({ message: 'Data e hora atualizadas!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/cargas/cancelar-aceite', authenticateToken, async (req, res) => {
    const { id } = req.body;
    const dono_id = req.user.id;
    try {
        const check = await pool.query('SELECT motorista_id, status FROM cargas WHERE id = $1 AND embarcador_id = $2', [id, dono_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Carga não encontrada ou sem permissão.' });
        
        const carga = check.rows[0];
        if (!carga.motorista_id) return res.status(400).json({ error: 'Não há motorista aceito nesta carga.' });

        await pool.query("UPDATE cargas SET status = 'DISPONIVEL', motorista_id = NULL WHERE id = $1", [id]);
        await pool.query("INSERT INTO ofertas_frete (carga_id, motorista_id, status) VALUES ($1, $2, 'CANCELADA_EMBARCADOR')", [id, carga.motorista_id]);

        res.json({ message: 'Aceite cancelado. Carga voltou para a fila de ofertas.' });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/cargas/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const dono_id = req.user.id;
    try {
        const check = await pool.query('SELECT status FROM cargas WHERE id = $1 AND embarcador_id = $2', [id, dono_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Carga não encontrada ou sem permissão.' });

        // NOVO: uma carga já ENTREGUE (finalizada) só pode ser cancelada
        // por um administrador — um funcionário OPERADOR pode cancelar
        // qualquer carga em aberto (ainda faz parte do dia a dia dele),
        // mas não mexe mais num registro de operação já concluída.
        if (check.rows[0].status === 'ENTREGUE' && !ehAdminEmbarcador(req.user)) {
            return res.status(403).json({ error: 'Apenas administradores podem cancelar uma carga já finalizada (entregue).' });
        }

        // CORRIGIDO: antes isso apagava a carga de vez do banco — o que
        // significava que não tinha como saber depois quantas cargas
        // foram canceladas (indicador do dashboard). Agora só marca como
        // CANCELADA (mantém o histórico), e solta a oferta pendente (se
        // houver) sem apagar a carga em si.
        await pool.query("UPDATE ofertas_frete SET status = 'CANCELADA_EMBARCADOR' WHERE carga_id = $1 AND status = 'ENVIADA'", [id]);
        await pool.query("UPDATE cargas SET status = 'CANCELADA' WHERE id = $1 AND embarcador_id = $2", [id, dono_id]);
        res.status(200).json({ message: 'Carga cancelada.' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/financeiro/resumo', authenticateToken, async (req, res) => {
    try {
        let sql = '';
        let params = [];
        if (req.user.usuario === 'admin_taclog') {
            sql = 'SELECT status, COUNT(*) as qtd, SUM(valor_frete) as total_frete, SUM(valor_pedagio) as total_pedagio FROM cargas GROUP BY status';
        } else {
            sql = 'SELECT status, COUNT(*) as qtd, SUM(valor_frete) as total_frete, SUM(valor_pedagio) as total_pedagio FROM cargas WHERE embarcador_id = $1 GROUP BY status';
            params = [req.user.id];
        }
        const result = await pool.query(sql, params);
        
        let resumo = { pagar: 0, aberto: 0, total_frete: 0, total_pedagio: 0 };
        result.rows.forEach(row => {
            const total = parseFloat(row.total_frete || 0) + parseFloat(row.total_pedagio || 0);
            resumo.total_frete += parseFloat(row.total_frete || 0);
            resumo.total_pedagio += parseFloat(row.total_pedagio || 0);
            if (row.status === 'ENTREGUE') resumo.pagar += total;
            else if (['DISPONIVEL', 'EM_ANDAMENTO', 'COLETADA', 'AGENDADA'].includes(row.status)) resumo.aberto += total;
        });
        res.json(resumo);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// ROTAS GESTÃO DE FROTA E MOTORISTA (TAC autônomo) — CAMINHÃO
// CADASTRO V2: agora aceita todos os campos da whitelist
// CAMPOS_CAMINHAO_PERMITIDOS, incluindo tipo_unidade_tratora
// (RIGIDO / CAVALO_MECANICO). Continua exigindo só placa no mínimo,
// os demais campos são opcionais e podem ser completados depois via PUT.
// =========================================================================
app.post('/api/caminhao/cadastro', authenticateToken, upload.single('foto_doc'), async (req, res) => {
    const c = req.body;
    const dono_id = req.user.id;
    try {
        const count = await pool.query('SELECT COUNT(*) FROM caminhoes WHERE proprietario_id = $1', [dono_id]);
        if (parseInt(count.rows[0].count) >= 3) {
            return res.status(400).json({ error: 'Limite de 3 caminhões atingido.' });
        }
        if (!validarTipoUnidadeTratora(c.tipo_unidade_tratora)) {
            return res.status(400).json({ error: 'tipo_unidade_tratora inválido. Use RIGIDO ou CAVALO_MECANICO.' });
        }
        const erroClassificacao = await resolverClassificacoes(c, 'caminhao');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });

        const fileUrl = req.file ? await uploadParaCloudinary(req.file.buffer, 'taclog/doc_veiculo', tipoDeRecursoCloudinary(req.file)) : null;

        const camposEnviados = CAMPOS_CAMINHAO_PERMITIDOS.filter(campo => c[campo] !== undefined && c[campo] !== '');
        const colunas = ['proprietario_id', 'doc_crlv_url', ...camposEnviados];
        const valores = [dono_id, fileUrl, ...camposEnviados.map(campo => c[campo])];
        const placeholders = valores.map((_, i) => `$${i + 1}`).join(', ');

        const sql = `INSERT INTO caminhoes (${colunas.join(', ')}) VALUES (${placeholders}) RETURNING id`;

        await pool.query(sql, valores);
        await pool.query('UPDATE motoristas SET possui_caminhao = TRUE WHERE id = $1', [dono_id]);
        res.status(201).json({ message: 'Caminhão cadastrado com sucesso!' });
    } catch (e) {
        console.error(e);
        if (e.code === '23505') {
            return res.status(400).json({ error: 'Placa, RENAVAM ou chassi já cadastrados no sistema.' });
        }
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/caminhao/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const dono_id = req.user.id;
    try {
        if (!validarTipoUnidadeTratora(c.tipo_unidade_tratora)) {
            return res.status(400).json({ error: 'tipo_unidade_tratora inválido. Use RIGIDO ou CAVALO_MECANICO.' });
        }
        const erroClassificacao = await resolverClassificacoes(c, 'caminhao');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        const camposEnviados = CAMPOS_CAMINHAO_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) {
            return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });
        }
        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        const result = await pool.query(
            `UPDATE caminhoes SET ${setClause} WHERE id = $${camposEnviados.length + 1} AND proprietario_id = $${camposEnviados.length + 2} RETURNING id`,
            [...valores, id, dono_id]
        );
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Caminhão não encontrado ou sem permissão.' });
        }
        res.status(200).json({ message: 'Caminhão atualizado com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// LISTAGEM DE CAMINHÕES DISPONÍVEIS PARA O MOTORISTA SELECIONAR
// Traz tanto caminhões próprios do motorista (proprietario_id) quanto
// caminhões de frota de qualquer transportadora que estejam livres (sem
// motorista dirigindo) ou já atribuídos a este próprio motorista.
// =========================================================================
app.get('/api/motorista/meus-caminhoes', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT c.*, e.razao_social as frota_nome_transportadora,
                   a.carreta_id as carreta_acoplada_id, cr.placa as carreta_acoplada_placa
            FROM caminhoes c
            LEFT JOIN embarcadores e ON e.id = c.embarcador_proprietario_id
            LEFT JOIN acoplamentos a ON a.caminhao_id = c.id AND a.data_fim IS NULL
            LEFT JOIN carretas cr ON cr.id = a.carreta_id
            WHERE c.proprietario_id = $1
               OR (c.embarcador_proprietario_id IS NOT NULL AND (c.motorista_atual_id IS NULL OR c.motorista_atual_id = $1))
            ORDER BY c.id DESC
        `, [req.user.id]);
        res.json(result.rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// ROTAS GESTÃO DE FROTA PRÓPRIA — EMBARCADOR TRANSPORTADORA
// Exclusivas para embarcadores com is_transportadora = true (ex: ZANIN).
// Os caminhões cadastrados aqui usam embarcador_proprietario_id (não
// proprietario_id, que é reservado para o fluxo de motorista autônomo).
// CADASTRO V2: mesma whitelist de campos do TAC autônomo.
// =========================================================================
// =========================================================================
// INDICADORES DO DASHBOARD — tudo numa chamada só, pra não deixar o
// front fazendo 5 requisições. Junta dados de `cargas` (Mercado) e
// `coletas_frota` (Coleta Própria) onde fizer sentido.
//
// Nota sobre "tempo médio de operação": não guardamos hoje o momento
// EXATO em que a carga foi coletada de verdade (só sabemos a data
// PROGRAMADA da coleta e o momento real da entrega). Por isso o cálculo
// usa "data programada da coleta" até "data/hora real da entrega" — é
// uma aproximação razoável e já funciona com o histórico existente. Se
// quiser precisão maior no futuro, dá pra gravar o timestamp real do
// momento em que o motorista confirma a coleta.
// =========================================================================
app.get('/api/embarcador/dashboard/indicadores', authenticateToken, async (req, res) => {
    const embarcador_id = req.user.id;
    try {
        // --- 1) Coletas e entregas por estado (as duas pizzas do mesmo card) ---
        const coletasPorEstado = await pool.query(`
            SELECT col_uf as uf, COUNT(*) as total FROM (
                SELECT col_uf FROM cargas WHERE embarcador_id = $1 AND status != 'CANCELADA' AND col_uf IS NOT NULL
                UNION ALL
                SELECT col_uf FROM coletas_frota WHERE embarcador_id = $1 AND status != 'CANCELADA' AND col_uf IS NOT NULL
            ) t GROUP BY col_uf ORDER BY total DESC
        `, [embarcador_id]);

        const entregasPorEstado = await pool.query(`
            SELECT ent_uf as uf, COUNT(*) as total FROM (
                SELECT ent_uf FROM cargas WHERE embarcador_id = $1 AND status != 'CANCELADA' AND ent_uf IS NOT NULL
                UNION ALL
                SELECT ent_uf FROM coletas_frota WHERE embarcador_id = $1 AND status != 'CANCELADA' AND ent_uf IS NOT NULL
            ) t GROUP BY ent_uf ORDER BY total DESC
        `, [embarcador_id]);

        // --- 2) Evolução mensal — Mercado x Frota Própria ---
        const evolucaoMercado = await pool.query(`
            SELECT TO_CHAR(data_coleta, 'YYYY-MM') as mes, COUNT(*) as total
            FROM cargas
            WHERE embarcador_id = $1 AND status != 'CANCELADA' AND data_coleta IS NOT NULL
              AND data_coleta > now() - interval '12 months'
            GROUP BY mes ORDER BY mes ASC
        `, [embarcador_id]);

        const evolucaoFrotaPropria = await pool.query(`
            SELECT TO_CHAR(data_coleta, 'YYYY-MM') as mes, COUNT(*) as total
            FROM coletas_frota
            WHERE embarcador_id = $1 AND status != 'CANCELADA' AND data_coleta IS NOT NULL
              AND data_coleta > now() - interval '12 months'
            GROUP BY mes ORDER BY mes ASC
        `, [embarcador_id]);

        // Junta os dois num mapa único mes -> {mercado, frota_propria}
        const mesesMap = {};
        for (const r of evolucaoMercado.rows) {
            mesesMap[r.mes] = mesesMap[r.mes] || { mes: r.mes, mercado: 0, frota_propria: 0 };
            mesesMap[r.mes].mercado = parseInt(r.total);
        }
        for (const r of evolucaoFrotaPropria.rows) {
            mesesMap[r.mes] = mesesMap[r.mes] || { mes: r.mes, mercado: 0, frota_propria: 0 };
            mesesMap[r.mes].frota_propria = parseInt(r.total);
        }
        const evolucaoMensal = Object.values(mesesMap).sort((a, b) => a.mes.localeCompare(b.mes));

        // --- 3) Cargas realizadas por caminhão (placa) ---
        const cargasPorCaminhao = await pool.query(`
            SELECT placa, COUNT(*) as total FROM (
                SELECT cam.placa FROM cargas c
                JOIN caminhoes cam ON cam.id = c.caminhao_designado_id
                WHERE c.embarcador_id = $1 AND c.status != 'CANCELADA' AND c.caminhao_designado_id IS NOT NULL
                UNION ALL
                SELECT caminhao_placa_snapshot as placa FROM coletas_frota
                WHERE embarcador_id = $1 AND status != 'CANCELADA' AND caminhao_placa_snapshot IS NOT NULL
            ) t GROUP BY placa ORDER BY total DESC
        `, [embarcador_id]);

        // --- 4) Tempo médio de operação — mês atual x mês anterior ---
        const tempoMedio = await pool.query(`
            SELECT
                TO_CHAR(finalizado_em, 'YYYY-MM') as mes,
                AVG(EXTRACT(DAY FROM (finalizado_em - data_coleta::timestamp))) as media_dias,
                COUNT(*) as total
            FROM (
                SELECT data_coleta, data_hora_finalizacao as finalizado_em
                FROM cargas
                WHERE embarcador_id = $1 AND status = 'ENTREGUE'
                  AND data_coleta IS NOT NULL AND data_hora_finalizacao IS NOT NULL
                UNION ALL
                SELECT data_coleta, atualizado_em as finalizado_em
                FROM coletas_frota
                WHERE embarcador_id = $1 AND status = 'ENTREGUE'
                  AND data_coleta IS NOT NULL AND atualizado_em IS NOT NULL
            ) t
            WHERE finalizado_em > now() - interval '2 months'
            GROUP BY mes ORDER BY mes DESC
            LIMIT 2
        `, [embarcador_id]);

        const hoje = new Date();
        const mesAtualStr = `${hoje.getFullYear()}-${String(hoje.getMonth() + 1).padStart(2, '0')}`;
        const mesAtual = tempoMedio.rows.find(r => r.mes === mesAtualStr) || { media_dias: null, total: 0 };
        const mesAnterior = tempoMedio.rows.find(r => r.mes !== mesAtualStr) || { media_dias: null, total: 0 };

        // Total de ofertas recusadas por motoristas (autônomos — motorista
        // funcionário não recusa, é designação direta) — pro card
        // "Rejeitadas (Motorista)".
        const rejeitadas = await pool.query(`
            SELECT COUNT(*) as total FROM ofertas_frete ofr
            JOIN cargas c ON c.id = ofr.carga_id
            WHERE c.embarcador_id = $1 AND ofr.status = 'REJEITADA'
        `, [embarcador_id]);

        res.json({
            coletas_por_estado: coletasPorEstado.rows,
            entregas_por_estado: entregasPorEstado.rows,
            evolucao_mensal: evolucaoMensal,
            cargas_por_caminhao: cargasPorCaminhao.rows,
            tempo_medio: {
                mes_atual: { media_dias: mesAtual.media_dias ? parseFloat(mesAtual.media_dias) : null, total: parseInt(mesAtual.total) || 0 },
                mes_anterior: { media_dias: mesAnterior.media_dias ? parseFloat(mesAnterior.media_dias) : null, total: parseInt(mesAnterior.total) || 0 },
            },
            total_ofertas_rejeitadas: parseInt(rejeitadas.rows[0].total) || 0,
        });
    } catch (e) {
        console.error('[DASHBOARD INDICADORES] erro:', e);
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/embarcador/frota', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        // CORRIGIDO: agora traz também a carreta acoplada no momento (se
        // houver) — necessário tanto pra exibir corretamente na tela de
        // Frota quanto pra decidir quais caminhões podem ser designados
        // manualmente numa carga (cavalo mecânico só pode ser escolhido
        // se já estiver com uma carreta acoplada). Também traz o nome do
        // motorista atualmente atribuído, pra exibir na tela.
        const result = await pool.query(`
            SELECT c.*, a.carreta_id as carreta_acoplada_id, cr.placa as carreta_acoplada_placa,
                   cr.tipo_carroceria as carreta_acoplada_carroceria,
                   cr.classificacao_carroceria as carreta_acoplada_class_carroceria,
                   m.nome as motorista_atual_nome, m.vinculo as motorista_atual_vinculo
            FROM caminhoes c
            LEFT JOIN acoplamentos a ON a.caminhao_id = c.id AND a.data_fim IS NULL
            LEFT JOIN carretas cr ON cr.id = a.carreta_id
            LEFT JOIN motoristas m ON m.id = c.motorista_atual_id
            WHERE c.embarcador_proprietario_id = $1
            ORDER BY c.id DESC
        `, [req.user.id]);
        res.json(result.rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// A TRANSPORTADORA atribui (ou desatribui) qual motorista FUNCIONÁRIO
// está dirigindo um caminhão da frota agora. Motorista autônomo continua
// "assumindo o volante" sozinho pelo app dele — isso aqui é só pro caso
// de funcionário, que não escolhe caminhão por conta própria.
// =========================================================================
app.put('/api/embarcador/frota/:id/atribuir-motorista', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const { motorista_id } = req.body; // null pra desatribuir

    try {
        const caminhao = await pool.query('SELECT id FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2', [id, req.user.id]);
        if (caminhao.rows.length === 0) return res.status(404).json({ error: 'Caminhão não encontrado ou sem permissão.' });

        if (motorista_id) {
            const motorista = await pool.query(
                'SELECT id, vinculo, embarcador_empregador_id FROM motoristas WHERE id = $1',
                [motorista_id]
            );
            if (motorista.rows.length === 0) return res.status(404).json({ error: 'Motorista não encontrado.' });
            if (motorista.rows[0].vinculo !== 'FUNCIONARIO' || motorista.rows[0].embarcador_empregador_id !== req.user.id) {
                return res.status(400).json({ error: 'Esse motorista não é funcionário da sua empresa.' });
            }

            // Se esse motorista já está dirigindo outro caminhão, solta o
            // outro primeiro — cada motorista só pode estar num caminhão
            // por vez.
            await pool.query('UPDATE caminhoes SET motorista_atual_id = NULL WHERE motorista_atual_id = $1', [motorista_id]);
        }

        await pool.query('UPDATE caminhoes SET motorista_atual_id = $1 WHERE id = $2', [motorista_id || null, id]);
        res.json({ message: motorista_id ? 'Motorista atribuído ao caminhão!' : 'Motorista desatribuído do caminhão.' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// CNH do motorista — a transportadora sobe o PDF/foto da CNH de um
// motorista funcionário dela (qualquer um já cadastrado, não só na
// hora de criar). Guarda a URL do Cloudinary em motoristas.cnh_url.
// =========================================================================
app.post('/api/embarcador/motoristas/:id/cnh', authenticateToken, exigirTransportadora, upload.single('arquivo'), async (req, res) => {
    const { id } = req.params;
    try {
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        const check = await pool.query(
            'SELECT id FROM motoristas WHERE id = $1 AND embarcador_empregador_id = $2',
            [id, req.user.id]
        );
        if (check.rows.length === 0) return res.status(404).json({ error: 'Motorista não encontrado ou sem permissão.' });

        // NOVO: sempre sobe como 'image' (mesmo sendo PDF) — o Cloudinary
        // consegue rasterizar a primeira página de um PDF como se fosse
        // uma foto, o que permite gerar uma miniatura de verdade na tela
        // (com 'raw', que usávamos antes, isso não é possível).
        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/cnh', 'image');
        await pool.query('UPDATE motoristas SET cnh_url = $1 WHERE id = $2', [url, id]);
        res.json({ message: 'CNH enviada com sucesso!', cnh_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// Documento do veículo (CRLV) — a transportadora sobe o PDF/foto do
// documento de um caminhão já cadastrado da frota dela. Reaproveita a
// mesma coluna doc_crlv_url já usada no cadastro inicial.
// =========================================================================
app.post('/api/embarcador/frota/:id/documento', authenticateToken, exigirTransportadora, upload.single('arquivo'), async (req, res) => {
    const { id } = req.params;
    try {
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        const check = await pool.query(
            'SELECT id FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2',
            [id, req.user.id]
        );
        if (check.rows.length === 0) return res.status(404).json({ error: 'Caminhão não encontrado ou sem permissão.' });

        // NOVO: sempre 'image' (mesmo em PDF) — habilita miniatura, igual
        // já fizemos com a CNH.
        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/doc_veiculo', 'image');
        await pool.query('UPDATE caminhoes SET doc_crlv_url = $1 WHERE id = $2', [url, id]);
        res.json({ message: 'Documento enviado com sucesso!', doc_crlv_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// Documento (CRLV) de uma carreta específica — mesmo padrão do caminhão.
app.post('/api/embarcador/carretas/:id/documento', authenticateToken, exigirTransportadora, upload.single('arquivo'), async (req, res) => {
    const { id } = req.params;
    try {
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        const check = await pool.query(
            'SELECT id FROM carretas WHERE id = $1 AND embarcador_proprietario_id = $2',
            [id, req.user.id]
        );
        if (check.rows.length === 0) return res.status(404).json({ error: 'Carreta não encontrada ou sem permissão.' });

        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/doc_veiculo', 'image');
        await pool.query('UPDATE carretas SET doc_crlv_url = $1 WHERE id = $2', [url, id]);
        res.json({ message: 'Documento enviado com sucesso!', doc_crlv_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// FOTOS DO VEÍCULO (caminhão/cavalo e carreta) — NOVO
// Cada veículo pode ter até 2 fotos opcionais: "lateral" (de lado) e
// "diagonal" (na diagonal, mostrando a PLACA). As embarcadoras costumam
// exigir essa foto antes de liberar a entrada no pátio.
// Quem pode enviar:
//   - transportadora: veículos da própria frota (embarcador_proprietario_id)
//   - motorista TAC: caminhão/carreta próprios
//   - motorista funcionário: o caminhão atribuído a ele e a carreta acoplada
// Colunas: foto_lateral_url / foto_diagonal_url (ver migracao_fotos_veiculos.sql)
// =========================================================================
const POSICOES_FOTO_VEICULO = { lateral: 'foto_lateral_url', diagonal: 'foto_diagonal_url' };

function colunaFotoVeiculo(posicao) {
    return POSICOES_FOTO_VEICULO[String(posicao || '').toLowerCase()] || null;
}

// Caminhão que o motorista está usando agora: o atribuído pela
// transportadora (funcionário) ou, senão, o ativo escolhido por ele (TAC).
async function buscarCaminhaoAtualDoMotorista(motoristaId) {
    const r = await pool.query(`
        SELECT c.id, c.placa, c.foto_lateral_url, c.foto_diagonal_url
        FROM caminhoes c
        WHERE c.motorista_atual_id = $1
           OR c.id = (SELECT caminhao_ativo_id FROM motoristas WHERE id = $1)
        ORDER BY (c.motorista_atual_id = $1) DESC, c.id DESC
        LIMIT 1
    `, [motoristaId]);
    return r.rows[0] || null;
}

// O motorista pode mexer nas fotos deste caminhão? (próprio, atribuído ou ativo)
async function motoristaPodeFotografarCaminhao(motoristaId, caminhaoId) {
    const r = await pool.query(`
        SELECT 1 FROM caminhoes c
        WHERE c.id = $2
          AND (c.proprietario_id = $1
               OR c.motorista_atual_id = $1
               OR c.id = (SELECT caminhao_ativo_id FROM motoristas WHERE id = $1))
    `, [motoristaId, caminhaoId]);
    return r.rows.length > 0;
}

// ...e desta carreta? (própria, ou acoplada ao caminhão que ele usa)
async function motoristaPodeFotografarCarreta(motoristaId, carretaId) {
    const r = await pool.query(`
        SELECT 1 FROM carretas cr
        WHERE cr.id = $2
          AND (cr.proprietario_id = $1
               OR cr.id IN (
                    SELECT a.carreta_id
                    FROM acoplamentos a
                    JOIN caminhoes c ON c.id = a.caminhao_id
                    WHERE a.data_fim IS NULL
                      AND (c.proprietario_id = $1
                           OR c.motorista_atual_id = $1
                           OR c.id = (SELECT caminhao_ativo_id FROM motoristas WHERE id = $1))
               ))
    `, [motoristaId, carretaId]);
    return r.rows.length > 0;
}

// --- Transportadora: foto do caminhão da frota -------------------------
app.post('/api/embarcador/frota/:id/foto/:posicao', authenticateToken, exigirTransportadora, upload.single('arquivo'), async (req, res) => {
    const { id, posicao } = req.params;
    try {
        const coluna = colunaFotoVeiculo(posicao);
        if (!coluna) return res.status(400).json({ error: 'Posição inválida (use lateral ou diagonal).' });
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        const check = await pool.query(
            'SELECT id FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2',
            [id, req.user.id]
        );
        if (check.rows.length === 0) return res.status(404).json({ error: 'Caminhão não encontrado ou sem permissão.' });

        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/foto_veiculo', 'image');
        await pool.query(`UPDATE caminhoes SET ${coluna} = $1 WHERE id = $2`, [url, id]);
        res.json({ message: 'Foto enviada com sucesso!', foto_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// --- Transportadora: foto da carreta da frota --------------------------
app.post('/api/embarcador/carretas/:id/foto/:posicao', authenticateToken, exigirTransportadora, upload.single('arquivo'), async (req, res) => {
    const { id, posicao } = req.params;
    try {
        const coluna = colunaFotoVeiculo(posicao);
        if (!coluna) return res.status(400).json({ error: 'Posição inválida (use lateral ou diagonal).' });
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        const check = await pool.query(
            'SELECT id FROM carretas WHERE id = $1 AND embarcador_proprietario_id = $2',
            [id, req.user.id]
        );
        if (check.rows.length === 0) return res.status(404).json({ error: 'Carreta não encontrada ou sem permissão.' });

        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/foto_veiculo', 'image');
        await pool.query(`UPDATE carretas SET ${coluna} = $1 WHERE id = $2`, [url, id]);
        res.json({ message: 'Foto enviada com sucesso!', foto_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// --- Motorista: caminhão atual + carreta acoplada, com as fotos --------
// Alimenta o botão "Fotos do caminhão" da tela inicial do app.
app.get('/api/motorista/veiculo-atual', authenticateToken, async (req, res) => {
    try {
        const caminhao = await buscarCaminhaoAtualDoMotorista(req.user.id);
        if (!caminhao) return res.json({ caminhao: null, carreta: null });

        const cr = await pool.query(`
            SELECT cr.id, cr.placa, cr.foto_lateral_url, cr.foto_diagonal_url
            FROM acoplamentos a
            JOIN carretas cr ON cr.id = a.carreta_id
            WHERE a.caminhao_id = $1 AND a.data_fim IS NULL
            ORDER BY a.data_inicio DESC NULLS LAST
            LIMIT 1
        `, [caminhao.id]);
        res.json({ caminhao, carreta: cr.rows[0] || null });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// --- Motorista: envia foto do caminhão (próprio ou atribuído) ----------
app.post('/api/motorista/caminhoes/:id/foto/:posicao', authenticateToken, upload.single('arquivo'), async (req, res) => {
    const { id, posicao } = req.params;
    try {
        const coluna = colunaFotoVeiculo(posicao);
        if (!coluna) return res.status(400).json({ error: 'Posição inválida (use lateral ou diagonal).' });
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        if (!(await motoristaPodeFotografarCaminhao(req.user.id, id))) {
            return res.status(403).json({ error: 'Você não tem permissão para alterar as fotos deste caminhão.' });
        }
        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/foto_veiculo', 'image');
        await pool.query(`UPDATE caminhoes SET ${coluna} = $1 WHERE id = $2`, [url, id]);
        res.json({ message: 'Foto enviada com sucesso!', foto_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// --- Motorista: envia foto da carreta (própria ou acoplada ao caminhão) -
app.post('/api/motorista/carretas/:id/foto/:posicao', authenticateToken, upload.single('arquivo'), async (req, res) => {
    const { id, posicao } = req.params;
    try {
        const coluna = colunaFotoVeiculo(posicao);
        if (!coluna) return res.status(400).json({ error: 'Posição inválida (use lateral ou diagonal).' });
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        if (!(await motoristaPodeFotografarCarreta(req.user.id, id))) {
            return res.status(403).json({ error: 'Você não tem permissão para alterar as fotos desta carreta.' });
        }
        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/foto_veiculo', 'image');
        await pool.query(`UPDATE carretas SET ${coluna} = $1 WHERE id = $2`, [url, id]);
        res.json({ message: 'Foto enviada com sucesso!', foto_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// MOTORISTAS FUNCIONÁRIOS — cadastrados diretamente pela transportadora.
// Diferente do motorista autônomo (que se cadastra sozinho e recebe ofertas
// com Aceitar/Recusar), o funcionário já nasce vinculado à empresa
// (vinculo='FUNCIONARIO', embarcador_empregador_id) e não passa por
// verificação de e-mail — quem garante a identidade dele é a própria
// transportadora que está cadastrando. Cargas dessa mesma transportadora
// são DESIGNADAS direto pra ele (ver designarOuOfertar, mais abaixo).
// =========================================================================
app.post('/api/embarcador/motoristas/cadastrar', authenticateToken, exigirTransportadora, async (req, res) => {
    const m = req.body;
    try {
        if (!m.nome || !m.cpf || !m.senha) {
            return res.status(400).json({ error: 'Nome, CPF e senha são obrigatórios.' });
        }
        const cpfLimpo = String(m.cpf).replace(/\D/g, '');
        const senha = String(m.senha).trim();

        const jaExiste = await pool.query('SELECT id FROM motoristas WHERE cpf = $1', [cpfLimpo]);
        if (jaExiste.rows.length > 0) {
            return res.status(400).json({ error: 'Já existe um motorista cadastrado com esse CPF.' });
        }
        // NOVO: mesma trava do autocadastro — CPF é ou de motorista, ou de
        // funcionário de escritório, nunca os dois AO MESMO TEMPO. Só
        // trava se o funcionário estiver ATIVO ou SUSPENSO; se já estiver
        // INATIVO (saiu da empresa), libera.
        const jaFuncionarioEscritorio = await pool.query(
            "SELECT id FROM funcionarios_embarcador WHERE cpf = $1 AND status IN ('ATIVO', 'SUSPENSO')",
            [cpfLimpo]
        );
        if (jaFuncionarioEscritorio.rows.length > 0) {
            return res.status(400).json({ error: 'Este CPF está cadastrado como funcionário de escritório ATIVO da transportadora. Não é possível também cadastrá-lo como motorista enquanto esse vínculo estiver ativo.' });
        }

        const result = await pool.query(`
            INSERT INTO motoristas
            (nome, cpf, email, senha_hash, telefone_celular, status_cadastro, email_verificado, vinculo, embarcador_empregador_id,
             endereco_cep, endereco_rua, endereco_numero, endereco_bairro, endereco_cidade, endereco_uf)
            VALUES ($1, $2, $3, $4, $5, 'ATIVO', true, 'FUNCIONARIO', $6, $7, $8, $9, $10, $11, $12)
            RETURNING id, nome, cpf
        `, [
            m.nome, cpfLimpo, m.email || null, senha, m.telefone_celular || null, req.user.id,
            m.endereco_cep || null, m.endereco_rua || null, m.endereco_numero || null,
            m.endereco_bairro || null, m.endereco_cidade || null, m.endereco_uf || null
        ]);

        res.status(201).json({ message: 'Motorista cadastrado com sucesso! Ele já pode logar com o CPF e a senha definida.', motorista: result.rows[0] });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/embarcador/motoristas', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        // NOVO: traz também qual caminhão (e carreta acoplada nele, se
        // houver) está atribuído a cada motorista agora — evita a tela
        // ter que perguntar isso separado pra cada um.
        const result = await pool.query(`
            SELECT m.id, m.nome, m.cpf, m.email, m.telefone_celular, m.status_disponibilidade, m.caminhao_ativo_id,
                   m.endereco_cep, m.endereco_rua, m.endereco_numero, m.endereco_bairro, m.endereco_cidade, m.endereco_uf,
                   m.cnh_url, m.foto_perfil_path,
                   cam.id as caminhao_atribuido_id, cam.placa as caminhao_atribuido_placa,
                   car.placa as carreta_atribuida_placa
            FROM motoristas m
            LEFT JOIN caminhoes cam ON cam.motorista_atual_id = m.id
            LEFT JOIN acoplamentos ac ON ac.caminhao_id = cam.id AND ac.data_fim IS NULL
            LEFT JOIN carretas car ON car.id = ac.carreta_id
            WHERE m.embarcador_empregador_id = $1 AND m.vinculo = 'FUNCIONARIO'
            ORDER BY m.nome ASC
        `, [req.user.id]);
        res.json(result.rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// EDITAR motorista funcionário — nome, telefone, e-mail, endereço.
// Não mexe em CPF nem senha aqui (fora do escopo desse edit simples).
// =========================================================================
app.put('/api/embarcador/motoristas/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const m = req.body;
    try {
        const check = await pool.query('SELECT id FROM motoristas WHERE id = $1 AND embarcador_empregador_id = $2', [id, req.user.id]);
        if (check.rows.length === 0) return res.status(404).json({ error: 'Motorista não encontrado ou sem permissão.' });
        if (!m.nome) return res.status(400).json({ error: 'Nome é obrigatório.' });

        await pool.query(`
            UPDATE motoristas SET
                nome = $1, email = $2, telefone_celular = $3,
                endereco_cep = $4, endereco_rua = $5, endereco_numero = $6,
                endereco_bairro = $7, endereco_cidade = $8, endereco_uf = $9
            WHERE id = $10
        `, [
            m.nome, m.email || null, m.telefone_celular || null,
            m.endereco_cep || null, m.endereco_rua || null, m.endereco_numero || null,
            m.endereco_bairro || null, m.endereco_cidade || null, m.endereco_uf || null,
            id
        ]);
        res.json({ message: 'Dados do motorista atualizados!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// Foto de perfil do motorista, enviada pela TRANSPORTADORA (o funcionário
// pode nem usar o app pra fazer isso sozinho) — mesma coluna que o
// próprio motorista usaria via /api/motorista/foto-perfil.
app.post('/api/embarcador/motoristas/:id/foto', authenticateToken, exigirTransportadora, upload.single('arquivo'), async (req, res) => {
    const { id } = req.params;
    try {
        if (!req.file) return res.status(400).json({ error: 'Nenhum arquivo enviado.' });
        const check = await pool.query('SELECT id FROM motoristas WHERE id = $1 AND embarcador_empregador_id = $2', [id, req.user.id]);
        if (check.rows.length === 0) return res.status(404).json({ error: 'Motorista não encontrado ou sem permissão.' });

        const url = await uploadParaCloudinary(req.file.buffer, 'taclog/foto_perfil', 'image');
        await pool.query('UPDATE motoristas SET foto_perfil_path = $1 WHERE id = $2', [url, id]);
        res.json({ message: 'Foto atualizada!', foto_url: url });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.delete('/api/embarcador/motoristas/:id', authenticateToken, exigirTransportadora, exigirPerfilAdmin, async (req, res) => {
    const { id } = req.params;
    try {
        const check = await pool.query('SELECT id FROM motoristas WHERE id = $1 AND embarcador_empregador_id = $2', [id, req.user.id]);
        if (check.rows.length === 0) return res.status(404).json({ error: 'Motorista não encontrado ou sem permissão.' });

        const emViagem = await pool.query(`SELECT id FROM cargas WHERE motorista_id = $1 AND status IN ('EM_ANDAMENTO', 'COLETADA')`, [id]);
        if (emViagem.rows.length > 0) {
            return res.status(400).json({ error: 'Este motorista está com uma carga em andamento — não é possível remover agora.' });
        }

        // Solta qualquer caminhão que esteja marcado como "sendo dirigido
        // por ele agora" antes de excluir — senão o banco trava a exclusão
        // pra não deixar essa referência apontando pra ninguém.
        await pool.query('UPDATE caminhoes SET motorista_atual_id = NULL WHERE motorista_atual_id = $1', [id]);

        // Também limpa a localização em tempo real dele, se houver.
        await pool.query('DELETE FROM localizacao_atual WHERE motorista_id = $1', [id]);

        await pool.query('DELETE FROM motoristas WHERE id = $1', [id]);
        res.json({ message: 'Motorista removido.' });
    } catch (e) {
        console.error(e);
        // Se ainda assim bater em alguma outra trava de integridade do
        // banco que a gente não previu, devolve mensagem legível em vez
        // do erro cru do PostgreSQL.
        if (e.code === '23503') {
            return res.status(400).json({ error: 'Não é possível remover este motorista — ele ainda tem registros vinculados no sistema (viagens, ofertas, etc.).' });
        }
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// O PRÓPRIO MOTORISTA consulta seu vínculo (autônomo x funcionário) e,
// se for funcionário, qual caminhão está atribuído a ele agora — usado
// pelo dashboard do app pra decidir o que mostrar (cards, disponibilidade
// sempre ligada, etc.) sem precisar relogar quando algo muda.
// =========================================================================
app.get('/api/motorista/meu-vinculo', authenticateToken, async (req, res) => {
    try {
        const m = await pool.query('SELECT vinculo, status_disponibilidade FROM motoristas WHERE id = $1', [req.user.id]);
        if (m.rows.length === 0) return res.status(404).json({ error: 'Motorista não encontrado.' });
        const vinculo = m.rows[0].vinculo || 'AUTONOMO';

        // NOVO: antes só o FUNCIONARIO (frota) recebia a placa do caminhão
        // aqui — o TAC autônomo nunca via, mesmo já tendo escolhido um
        // caminhão ativo (caminhao_ativo_id) lá em "Minha Frota". Agora os
        // dois casos são cobertos, cada um lendo do campo certo: o
        // funcionário via caminhoes.motorista_atual_id (atribuído pela
        // transportadora), o autônomo via motoristas.caminhao_ativo_id
        // (escolhido por ele mesmo).
        let caminhaoPlaca = null;
        if (vinculo === 'FUNCIONARIO') {
            const cam = await pool.query('SELECT placa FROM caminhoes WHERE motorista_atual_id = $1 LIMIT 1', [req.user.id]);
            if (cam.rows.length > 0) caminhaoPlaca = cam.rows[0].placa;
        } else {
            const cam = await pool.query(
                'SELECT cam.placa FROM motoristas m JOIN caminhoes cam ON cam.id = m.caminhao_ativo_id WHERE m.id = $1',
                [req.user.id]
            );
            if (cam.rows.length > 0) caminhaoPlaca = cam.rows[0].placa;
        }

        // NOVO: devolve também a disponibilidade persistida no servidor —
        // o app usa isso pra: 1) mostrar um indicador de status na tela
        // inicial (DISPONÍVEL/INDISPONÍVEL), e 2) restaurar o estado do
        // switch na tela do mapa quando o motorista TAC volta pra essa tela
        // (antes, o switch sempre "nascia" desligado de novo a cada entrada
        // na tela, mesmo que ele nunca tivesse se marcado como indisponível).
        res.json({
            vinculo,
            caminhao_atribuido_placa: caminhaoPlaca,
            disponivel: m.rows[0].status_disponibilidade === true,
        });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// "Agenda" do motorista — junta cargas do Mercado designadas + Coletas
// Próprias designadas pro caminhão que ele está dirigindo agora, numa
// lista só, ordenada por data/hora. Alimenta a lista de "balões" no
// dashboard do app.
// =========================================================================
app.get('/api/motorista/minhas-agendadas', authenticateToken, async (req, res) => {
    try {
        const motoristaId = req.user.id;
        const cam = await pool.query('SELECT id FROM caminhoes WHERE motorista_atual_id = $1', [motoristaId]);
        if (cam.rows.length === 0) return res.json([]);
        const caminhaoId = cam.rows[0].id;

        const cargas = await pool.query(`
            SELECT id, descricao, data_coleta, hora_coleta, col_cidade, col_uf, ent_cidade, ent_uf, 'mercado' as origem
            FROM cargas
            WHERE caminhao_designado_id = $1 AND status IN ('AGENDADA', 'DISPONIVEL', 'EM_ANDAMENTO')
              AND data_coleta IS NOT NULL
        `, [caminhaoId]);

        const coletas = await pool.query(`
            SELECT id, tipo_carga as descricao, data_coleta, hora_coleta, col_cidade, col_uf, ent_cidade, ent_uf, 'coleta_propria' as origem
            FROM coletas_frota
            WHERE caminhao_id = $1 AND status NOT IN ('ENTREGUE', 'CANCELADA')
        `, [caminhaoId]);

        const todas = [...cargas.rows, ...coletas.rows].sort((a, b) => {
            const da = new Date(`${a.data_coleta}T${a.hora_coleta || '00:00'}`);
            const db = new Date(`${b.data_coleta}T${b.hora_coleta || '00:00'}`);
            return da - db;
        });

        res.json(todas);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// Detalhe completo de uma carga/coleta agendada (endereço completo pra
// geolocalizar) — o app carrega isso quando o motorista toca no card ou
// no botão "COLETAR" do popup, pra abrir a tela de navegação já com os
// dados prontos, igual ao fluxo padrão do TAC.
// =========================================================================
app.get('/api/motorista/detalhe-agendada', authenticateToken, async (req, res) => {
    const { origem, id } = req.query;
    const motoristaId = req.user.id;
    try {
        if (origem === 'mercado') {
            const r = await pool.query(`
                SELECT c.* FROM cargas c
                JOIN caminhoes cam ON cam.id = c.caminhao_designado_id
                WHERE c.id = $1 AND cam.motorista_atual_id = $2
            `, [id, motoristaId]);
            if (r.rows.length === 0) return res.status(404).json({ error: 'Carga não encontrada.' });
            res.json({ ...r.rows[0], origem: 'mercado' });
        } else {
            const r = await pool.query(`
                SELECT co.* FROM coletas_frota co
                JOIN caminhoes cam ON cam.id = co.caminhao_id
                WHERE co.id = $1 AND cam.motorista_atual_id = $2
            `, [id, motoristaId]);
            if (r.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada.' });
            // O valor do frete é dado comercial da transportadora — não vai pro app do motorista.
            const { valor_frete: _valorFreteOculto, ...coletaSemValor } = r.rows[0];
            res.json({ ...coletaSemValor, origem: 'coleta_propria', descricao: r.rows[0].tipo_carga });
        }
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// Ciclo de vida unificado (Mercado + Coleta Própria) pro motorista — o
// app chama sempre esses 3 endpoints, passando "origem", e o backend
// decide sozinho em qual tabela mexer. Mercado já ficava em EM_ANDAMENTO
// desde a designação, então "iniciar" é só validação; Coleta Própria
// precisa da transição explícita.
// =========================================================================
app.post('/api/motorista/coleta/iniciar', authenticateToken, async (req, res) => {
    const { origem, id } = req.body;
    const motoristaId = req.user.id;
    try {
        if (origem === 'mercado') {
            const check = await pool.query(`
                SELECT c.id FROM cargas c JOIN caminhoes cam ON cam.id = c.caminhao_designado_id
                WHERE c.id = $1 AND cam.motorista_atual_id = $2
            `, [id, motoristaId]);
            if (check.rows.length === 0) return res.status(404).json({ error: 'Carga não encontrada.' });
        } else {
            const check = await pool.query(`
                SELECT co.id FROM coletas_frota co JOIN caminhoes cam ON cam.id = co.caminhao_id
                WHERE co.id = $1 AND cam.motorista_atual_id = $2
            `, [id, motoristaId]);
            if (check.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada.' });
            await pool.query("UPDATE coletas_frota SET status = 'EM_ANDAMENTO' WHERE id = $1", [id]);
        }
        res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/motorista/coleta/confirmar', authenticateToken, async (req, res) => {
    const { origem, id } = req.body;
    const motoristaId = req.user.id;
    try {
        if (origem === 'mercado') {
            await pool.query("UPDATE cargas SET status = 'COLETADA' WHERE id = $1 AND motorista_id = $2", [id, motoristaId]);
        } else {
            await pool.query(`
                UPDATE coletas_frota SET status = 'COLETADA'
                WHERE id = $1 AND caminhao_id IN (SELECT id FROM caminhoes WHERE motorista_atual_id = $2)
            `, [id, motoristaId]);
        }
        res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/motorista/coleta/finalizar', authenticateToken, async (req, res) => {
    const { origem, id, lat, lng } = req.body;
    const motoristaId = req.user.id;
    try {
        if (origem === 'mercado') {
            await pool.query(
                "UPDATE cargas SET status = 'ENTREGUE', data_hora_finalizacao = now(), lat_finalizacao = $1, lng_finalizacao = $2 WHERE id = $3 AND motorista_id = $4",
                [lat, lng, id, motoristaId]
            );
        } else {
            await pool.query(`
                UPDATE coletas_frota SET status = 'ENTREGUE', atualizado_em = now()
                WHERE id = $1 AND caminhao_id IN (SELECT id FROM caminhoes WHERE motorista_atual_id = $2)
            `, [id, motoristaId]);
        }
        res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});


app.post('/api/embarcador/frota/cadastro', authenticateToken, exigirTransportadora, async (req, res) => {
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        if (!validarTipoUnidadeTratora(c.tipo_unidade_tratora)) {
            return res.status(400).json({ error: 'tipo_unidade_tratora inválido. Use RIGIDO ou CAVALO_MECANICO.' });
        }
        const erroClassificacao = await resolverClassificacoes(c, 'caminhao');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        const camposEnviados = CAMPOS_CAMINHAO_PERMITIDOS.filter(campo => c[campo] !== undefined && c[campo] !== '');
        const colunas = ['embarcador_proprietario_id', 'status_uso', ...camposEnviados];
        const valores = [embarcador_id, 'PARADO', ...camposEnviados.map(campo => c[campo])];
        const placeholders = valores.map((_, i) => `$${i + 1}`).join(', ');

        const sql = `INSERT INTO caminhoes (${colunas.join(', ')}) VALUES (${placeholders}) RETURNING id`;
        await pool.query(sql, valores);
        res.status(201).json({ message: 'Caminhão cadastrado na frota com sucesso!' });
    } catch (e) {
        console.error(e);
        if (e.code === '23505') {
            return res.status(400).json({ error: 'Placa, RENAVAM ou chassi já cadastrados no sistema.' });
        }
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/frota/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        if (!validarTipoUnidadeTratora(c.tipo_unidade_tratora)) {
            return res.status(400).json({ error: 'tipo_unidade_tratora inválido. Use RIGIDO ou CAVALO_MECANICO.' });
        }
        const erroClassificacao = await resolverClassificacoes(c, 'caminhao');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        const check = await pool.query('SELECT id FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2', [id, embarcador_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Caminhão não encontrado ou sem permissão.' });

        const camposEnviados = CAMPOS_CAMINHAO_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) {
            return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });
        }
        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        await pool.query(
            `UPDATE caminhoes SET ${setClause} WHERE id = $${camposEnviados.length + 1} AND embarcador_proprietario_id = $${camposEnviados.length + 2}`,
            [...valores, id, embarcador_id]
        );
        res.json({ message: 'Caminhão atualizado com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.delete('/api/embarcador/frota/:id', authenticateToken, exigirTransportadora, exigirPerfilAdmin, async (req, res) => {
    const { id } = req.params;
    const embarcador_id = req.user.id;
    try {
        const check = await pool.query('SELECT id FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2', [id, embarcador_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Caminhão não encontrado ou sem permissão.' });

        await pool.query('DELETE FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2', [id, embarcador_id]);
        res.json({ message: 'Caminhão removido da frota com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// CADASTRO V2 — CARRETAS (TAC autônomo)
// Segue o mesmo padrão do caminhão: proprietario_id = motorista dono.
// =========================================================================
app.post('/api/carreta/cadastro', authenticateToken, upload.single('foto_doc'), async (req, res) => {
    const c = req.body;
    const dono_id = req.user.id;
    try {
        const erroClassificacao = await resolverClassificacoes(c, 'carreta');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        if (!c.placa || !c.renavam || !c.chassi || !c.tipo_carroceria) {
            return res.status(400).json({ error: 'Campos obrigatórios: placa, renavam, chassi, tipo_carroceria' });
        }
        const fileUrl = req.file ? await uploadParaCloudinary(req.file.buffer, 'taclog/doc_veiculo', tipoDeRecursoCloudinary(req.file)) : null;

        const camposEnviados = CAMPOS_CARRETA_PERMITIDOS.filter(campo => c[campo] !== undefined && c[campo] !== '');
        const colunas = ['proprietario_id', 'doc_crlv_url', ...camposEnviados];
        const valores = [dono_id, fileUrl, ...camposEnviados.map(campo => c[campo])];
        const placeholders = valores.map((_, i) => `$${i + 1}`).join(', ');

        const sql = `INSERT INTO carretas (${colunas.join(', ')}) VALUES (${placeholders}) RETURNING id`;
        await pool.query(sql, valores);
        res.status(201).json({ message: 'Carreta cadastrada com sucesso!' });
    } catch (e) {
        console.error(e);
        if (e.code === '23505') {
            return res.status(400).json({ error: 'Placa, RENAVAM ou chassi já cadastrados no sistema.' });
        }
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/carreta/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const dono_id = req.user.id;
    try {
        const erroClassificacao = await resolverClassificacoes(c, 'carreta');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        const camposEnviados = CAMPOS_CARRETA_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) {
            return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });
        }
        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        const result = await pool.query(
            `UPDATE carretas SET ${setClause} WHERE id = $${camposEnviados.length + 1} AND proprietario_id = $${camposEnviados.length + 2} RETURNING id`,
            [...valores, id, dono_id]
        );
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Carreta não encontrada ou sem permissão.' });
        }
        res.status(200).json({ message: 'Carreta atualizada com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.delete('/api/carreta/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const dono_id = req.user.id;
    try {
        const result = await pool.query(
            'UPDATE carretas SET ativo = FALSE WHERE id = $1 AND proprietario_id = $2 RETURNING id',
            [id, dono_id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Carreta não encontrada ou sem permissão.' });
        res.json({ message: 'Carreta removida com sucesso!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Lista carretas do próprio motorista + carretas da frota da transportadora
// à qual ele está vinculado no momento (via caminhão de frota selecionado)
app.get('/api/motorista/minhas-carretas', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT cr.*, e.razao_social as frota_nome_transportadora,
                   a.caminhao_id as acoplada_em_caminhao_id
            FROM carretas cr
            LEFT JOIN embarcadores e ON e.id = cr.embarcador_proprietario_id
            LEFT JOIN acoplamentos a ON a.carreta_id = cr.id AND a.data_fim IS NULL
            WHERE cr.ativo = TRUE
              AND (
                cr.proprietario_id = $1
                OR cr.embarcador_proprietario_id IN (
                    SELECT embarcador_proprietario_id FROM caminhoes
                    WHERE motorista_atual_id = $1 AND embarcador_proprietario_id IS NOT NULL
                )
              )
            ORDER BY cr.id DESC
        `, [req.user.id]);
        res.json(result.rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// CADASTRO V2 — CARRETAS (frota da transportadora)
// =========================================================================
app.get('/api/embarcador/frota/carretas', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT * FROM carretas WHERE embarcador_proprietario_id = $1 AND ativo = TRUE ORDER BY id DESC',
            [req.user.id]
        );
        res.json(result.rows);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/embarcador/frota/carreta/cadastro', authenticateToken, exigirTransportadora, async (req, res) => {
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        const erroClassificacao = await resolverClassificacoes(c, 'carreta');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        if (!c.placa || !c.renavam || !c.chassi || !c.tipo_carroceria) {
            return res.status(400).json({ error: 'Campos obrigatórios: placa, renavam, chassi, tipo_carroceria' });
        }
        const camposEnviados = CAMPOS_CARRETA_PERMITIDOS.filter(campo => c[campo] !== undefined && c[campo] !== '');
        const colunas = ['embarcador_proprietario_id', ...camposEnviados];
        const valores = [embarcador_id, ...camposEnviados.map(campo => c[campo])];
        const placeholders = valores.map((_, i) => `$${i + 1}`).join(', ');

        const sql = `INSERT INTO carretas (${colunas.join(', ')}) VALUES (${placeholders}) RETURNING id`;
        await pool.query(sql, valores);
        res.status(201).json({ message: 'Carreta cadastrada na frota com sucesso!' });
    } catch (e) {
        console.error(e);
        if (e.code === '23505') {
            return res.status(400).json({ error: 'Placa, RENAVAM ou chassi já cadastrados no sistema.' });
        }
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/frota/carreta/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        const check = await pool.query('SELECT id FROM carretas WHERE id = $1 AND embarcador_proprietario_id = $2', [id, embarcador_id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Carreta não encontrada ou sem permissão.' });

        const erroClassificacao = await resolverClassificacoes(c, 'carreta');
        if (erroClassificacao) return res.status(400).json({ error: erroClassificacao });
        const camposEnviados = CAMPOS_CARRETA_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) {
            return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });
        }
        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        await pool.query(
            `UPDATE carretas SET ${setClause} WHERE id = $${camposEnviados.length + 1} AND embarcador_proprietario_id = $${camposEnviados.length + 2}`,
            [...valores, id, embarcador_id]
        );
        res.json({ message: 'Carreta atualizada com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.delete('/api/embarcador/frota/carreta/:id', authenticateToken, exigirTransportadora, exigirPerfilAdmin, async (req, res) => {
    const { id } = req.params;
    const embarcador_id = req.user.id;
    try {
        const result = await pool.query(
            'UPDATE carretas SET ativo = FALSE WHERE id = $1 AND embarcador_proprietario_id = $2 RETURNING id',
            [id, embarcador_id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Carreta não encontrada ou sem permissão.' });
        res.json({ message: 'Carreta removida da frota com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// ACOPLAMENTO — liga um caminhão CAVALO_MECANICO a uma carreta.
// Fecha automaticamente qualquer acoplamento anterior do caminhão e/ou
// da carreta (troca de carreta), garantindo no banco que nunca existam
// dois acoplamentos ativos simultâneos (índices únicos parciais).
// =========================================================================
app.post('/api/motorista/acoplar-carreta', authenticateToken, async (req, res) => {
    const { caminhao_id, carreta_id } = req.body;
    const user_id = req.user.id;
    const role = req.user.role;

    if (!caminhao_id || !carreta_id) {
        return res.status(400).json({ error: 'caminhao_id e carreta_id são obrigatórios.' });
    }

    const client = await pool.connect();
    try {
        await client.query('BEGIN');

        const caminhaoRes = await client.query('SELECT * FROM caminhoes WHERE id = $1', [caminhao_id]);
        if (caminhaoRes.rows.length === 0) {
            await client.query('ROLLBACK');
            return res.status(404).json({ error: 'Caminhão não encontrado.' });
        }
        const caminhao = caminhaoRes.rows[0];

        if (caminhao.tipo_unidade_tratora !== 'CAVALO_MECANICO') {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: 'Somente caminhões do tipo CAVALO_MECANICO podem acoplar carreta.' });
        }

        const permissaoCaminhao = (
            caminhao.proprietario_id === user_id ||
            caminhao.embarcador_proprietario_id === user_id ||
            caminhao.motorista_atual_id === user_id
        );
        if (!permissaoCaminhao) {
            await client.query('ROLLBACK');
            return res.status(403).json({ error: 'Você não tem permissão sobre este caminhão.' });
        }

        const carretaRes = await client.query('SELECT * FROM carretas WHERE id = $1 AND ativo = TRUE', [carreta_id]);
        if (carretaRes.rows.length === 0) {
            await client.query('ROLLBACK');
            return res.status(404).json({ error: 'Carreta não encontrada.' });
        }
        const carreta = carretaRes.rows[0];

        const permissaoCarreta = (
            carreta.proprietario_id === user_id ||
            carreta.embarcador_proprietario_id === user_id ||
            (caminhao.embarcador_proprietario_id !== null && carreta.embarcador_proprietario_id === caminhao.embarcador_proprietario_id)
        );
        if (!permissaoCarreta) {
            await client.query('ROLLBACK');
            return res.status(403).json({ error: 'Você não tem permissão sobre esta carreta.' });
        }

        // NOVO: uma carreta já acoplada em OUTRO caminhão não pode ser
        // acoplada de novo — precisa ser desacoplada antes (a pedido do
        // Marcelo). A troca só é automática do lado do caminhão (trocar a
        // carreta que ELE está puxando), nunca do lado da carreta.
        const acoplamentoAtivoCarreta = await client.query(
            `SELECT caminhao_id FROM acoplamentos WHERE carreta_id = $1 AND data_fim IS NULL`,
            [carreta_id]
        );
        if (acoplamentoAtivoCarreta.rows.length > 0 && acoplamentoAtivoCarreta.rows[0].caminhao_id !== parseInt(caminhao_id)) {
            await client.query('ROLLBACK');
            return res.status(409).json({ error: 'Esta carreta já está acoplada a outro caminhão. Desacople-a primeiro para poder acoplar em um novo.' });
        }

        // Fecha acoplamento ativo anterior do caminhão (troca de carreta)
        await client.query(`UPDATE acoplamentos SET data_fim = now() WHERE caminhao_id = $1 AND data_fim IS NULL`, [caminhao_id]);

        const responsavelCampo = role === 'embarcador' ? 'embarcador_id' : 'motorista_id';
        const novoAcoplamento = await client.query(
            `INSERT INTO acoplamentos (caminhao_id, carreta_id, ${responsavelCampo}) VALUES ($1, $2, $3) RETURNING *`,
            [caminhao_id, carreta_id, user_id]
        );

        await client.query('COMMIT');
        res.status(201).json(novoAcoplamento.rows[0]);
    } catch (e) {
        await client.query('ROLLBACK');
        console.error('Erro ao acoplar carreta:', e);
        res.status(500).json({ error: e.message });
    } finally {
        client.release();
    }
});

app.post('/api/motorista/desacoplar-carreta', authenticateToken, async (req, res) => {
    const { caminhao_id } = req.body;
    if (!caminhao_id) return res.status(400).json({ error: 'caminhao_id é obrigatório.' });
    try {
        const result = await pool.query(
            `UPDATE acoplamentos SET data_fim = now() WHERE caminhao_id = $1 AND data_fim IS NULL RETURNING *`,
            [caminhao_id]
        );
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Este caminhão não possui acoplamento ativo.' });
        }
        res.json({ message: 'Carreta desacoplada com sucesso!', acoplamento: result.rows[0] });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/caminhao/:id/acoplamento-ativo', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT a.*, cr.placa as carreta_placa, cr.tipo_carroceria
            FROM acoplamentos a
            JOIN carretas cr ON cr.id = a.carreta_id
            WHERE a.caminhao_id = $1 AND a.data_fim IS NULL
        `, [req.params.id]);
        res.json(result.rows[0] || null);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/caminhao/:id/historico-acoplamentos', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT a.*, cr.placa as carreta_placa, cr.tipo_carroceria
            FROM acoplamentos a
            JOIN carretas cr ON cr.id = a.carreta_id
            WHERE a.caminhao_id = $1
            ORDER BY a.data_inicio DESC
        `, [req.params.id]);
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// CONFIGURAÇÕES DO EMBARCADOR TRANSPORTADORA
// Hoje guarda apenas a distância máxima que o sistema aceita buscar um
// caminhão da frota própria para uma coleta. distancia_maxima_frota_km = 0
// significa "sem limite" (busca o caminhão da frota mais próximo, não
// importa a distância).
// =========================================================================
app.get('/api/embarcador/configuracoes', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT distancia_maxima_frota_km, permite_ofertas_mercado_frota FROM embarcadores WHERE id = $1',
            [req.user.id]
        );
        res.json(result.rows[0] || { distancia_maxima_frota_km: 0, permite_ofertas_mercado_frota: false });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/configuracoes', authenticateToken, exigirTransportadora, async (req, res) => {
    // NOVO: aceita os dois campos de forma independente — atualiza só o
    // que foi enviado no corpo da requisição. Isso mantém o front antigo
    // (que só manda distancia_maxima_frota_km) funcionando sem mudança, e
    // permite o novo interruptor (permite_ofertas_mercado_frota) salvar
    // sozinho, sem precisar reenviar a distância junto.
    const { distancia_maxima_frota_km, permite_ofertas_mercado_frota } = req.body;
    try {
        const campos = [];
        const valores = [];
        let i = 1;

        if (distancia_maxima_frota_km !== undefined) {
            const valor = parseFloat(distancia_maxima_frota_km);
            if (isNaN(valor) || valor < 0) {
                return res.status(400).json({ error: 'Distância máxima inválida. Use 0 para "sem limite" ou um valor positivo em Km.' });
            }
            campos.push(`distancia_maxima_frota_km = $${i++}`);
            valores.push(valor);
        }

        if (permite_ofertas_mercado_frota !== undefined) {
            campos.push(`permite_ofertas_mercado_frota = $${i++}`);
            valores.push(permite_ofertas_mercado_frota === true);
        }

        if (campos.length === 0) {
            return res.status(400).json({ error: 'Nenhuma configuração informada.' });
        }

        valores.push(req.user.id);
        await pool.query(`UPDATE embarcadores SET ${campos.join(', ')} WHERE id = $${i}`, valores);
        res.json({ message: 'Configurações salvas com sucesso!' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// NOTIFICAÇÕES DO EMBARCADOR (ícone de sino no dashboard)
// Alimentadas hoje pelo scheduler verificarPreferenciaFrota() (Fase 5),
// quando a frota própria não está disponível ou está fora do limite de
// distância configurado. Disponível para qualquer embarcador (não exige
// ser transportadora), pensando em futuras notificações de outros tipos.
// =========================================================================
app.get('/api/embarcador/notificacoes', authenticateToken, async (req, res) => {
    if (req.user.role !== 'embarcador') return res.status(403).json({ error: 'Apenas embarcadores possuem notificações.' });
    try {
        const result = await pool.query(
            'SELECT * FROM notificacoes_embarcador WHERE embarcador_id = $1 ORDER BY data_criacao DESC LIMIT 50',
            [req.user.id]
        );
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/embarcador/notificacoes/contagem', authenticateToken, async (req, res) => {
    if (req.user.role !== 'embarcador') return res.status(403).json({ error: 'Apenas embarcadores possuem notificações.' });
    try {
        const result = await pool.query(
            'SELECT COUNT(*) FROM notificacoes_embarcador WHERE embarcador_id = $1 AND lida = false',
            [req.user.id]
        );
        res.json({ total_nao_lidas: parseInt(result.rows[0].count) });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/notificacoes/:id/marcar-lida', authenticateToken, async (req, res) => {
    const { id } = req.params;
    try {
        const check = await pool.query('SELECT id FROM notificacoes_embarcador WHERE id = $1 AND embarcador_id = $2', [id, req.user.id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Notificação não encontrada ou sem permissão.' });

        await pool.query('UPDATE notificacoes_embarcador SET lida = true WHERE id = $1', [id]);
        res.json({ message: 'Notificação marcada como lida.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/notificacoes/marcar-todas-lidas', authenticateToken, async (req, res) => {
    try {
        await pool.query('UPDATE notificacoes_embarcador SET lida = true WHERE embarcador_id = $1 AND lida = false', [req.user.id]);
        res.json({ message: 'Todas as notificações foram marcadas como lidas.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// MAPA AO VIVO DA FROTA — só os caminhões da PRÓPRIA transportadora
// (diferente de /api/motoristas/ativos, que é global). Mesma lógica de
// "livre" (sem carga/coleta em andamento agora) já usada no card do
// dashboard, só que escopada e trazendo também os caminhões SEM
// motorista ainda (aparecem no mapa como "sem motorista", útil pra
// saber que aquele caminhão está parado na garagem).
// =========================================================================
app.get('/api/embarcador/frota/mapa-ao-vivo', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT cam.id as caminhao_id, cam.placa, m.id as motorista_id, m.nome as motorista_nome,
                ST_Y(l.ponto::geometry) as lat, ST_X(l.ponto::geometry) as lng,
                l.timestamp_atualizacao,
                NOT EXISTS (
                    SELECT 1 FROM cargas c WHERE c.motorista_id = m.id AND c.status IN ('EM_ANDAMENTO', 'COLETADA')
                ) AND NOT EXISTS (
                    SELECT 1 FROM coletas_frota co WHERE co.caminhao_id = cam.id AND co.status IN ('EM_ANDAMENTO', 'COLETADA')
                ) as livre
            FROM caminhoes cam
            JOIN motoristas m ON m.id = cam.motorista_atual_id
            JOIN localizacao_atual l ON l.motorista_id = m.id
            WHERE cam.embarcador_proprietario_id = $1
            AND l.timestamp_atualizacao > now() - interval '2 minutes'
        `, [req.user.id]);
        res.json(result.rows);
    } catch (e) {
        console.error("Erro no mapa ao vivo da frota:", e);
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/motoristas/ativos', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT m.id, m.nome, cam.placa, ST_Y(l.ponto::geometry) as lat, ST_X(l.ponto::geometry) as lng,
                NOT EXISTS (
                    SELECT 1 FROM cargas c WHERE c.motorista_id = m.id AND c.status IN ('EM_ANDAMENTO', 'COLETADA')
                ) AND NOT EXISTS (
                    SELECT 1 FROM coletas_frota co JOIN caminhoes camx ON camx.id = co.caminhao_id
                    WHERE camx.motorista_atual_id = m.id AND co.status IN ('EM_ANDAMENTO', 'COLETADA')
                ) as livre
            FROM motoristas m
            JOIN localizacao_atual l ON m.id = l.motorista_id
            LEFT JOIN caminhoes cam ON m.caminhao_ativo_id = cam.id
            WHERE m.status_disponibilidade = true
            AND l.timestamp_atualizacao > now() - interval '2 minutes'
        `);
        // NOVO: "online" (status_disponibilidade + GPS recente) e "livre"
        // (online E sem nenhuma carga/coleta em andamento agora) são
        // coisas diferentes — antes o card do dashboard misturava os
        // dois num número só, contando até quem já estava em viagem.
        const totalLivres = result.rows.filter(r => r.livre).length;
        res.json({ total: result.rows.length, total_online: result.rows.length, total_livres: totalLivres, motoristas: result.rows });
    } catch (e) {
        console.error("Erro na API de ativos:", e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// SELEÇÃO DE CAMINHÃO ATIVO PELO MOTORISTA
// Aceita tanto caminhões próprios do motorista (fluxo TAC autônomo,
// proprietario_id = motorista) quanto caminhões de frota de uma transporta-
// dora (embarcador_proprietario_id preenchido) — isso permite que motoristas
// empregados por uma transportadora (ex: ZANIN) dirijam a frota dela e
// apareçam para o matchmaking de preferência de frota.
// =========================================================================
app.post('/api/motorista/selecionar-caminhao', authenticateToken, async (req, res) => {
    const { caminhao_id } = req.body;
    const motorista_id = req.user.id;
    
    const client = await pool.connect();
    try {
        const viagem = await client.query(`SELECT id FROM cargas WHERE motorista_id = $1 AND status IN ('EM_ANDAMENTO', 'COLETADA')`, [motorista_id]);
        if (viagem.rows.length > 0) {
            return res.status(400).json({ error: 'Você tem uma carga em trânsito! Finalize a entrega antes de trocar de caminhão.' });
        }

        const caminhaoValido = await client.query(
            'SELECT id FROM caminhoes WHERE id = $1 AND (proprietario_id = $2 OR embarcador_proprietario_id IS NOT NULL)',
            [caminhao_id, motorista_id]
        );
        if (caminhaoValido.rows.length === 0) {
            return res.status(403).json({ error: 'Caminhão não encontrado ou você não tem permissão para selecioná-lo.' });
        }

        await client.query('BEGIN');
        await client.query("UPDATE caminhoes SET status_uso = 'PARADO', motorista_atual_id = NULL WHERE motorista_atual_id = $1", [motorista_id]);
        await client.query("UPDATE caminhoes SET status_uso = 'EM_USO', motorista_atual_id = $1 WHERE id = $2", [motorista_id, caminhao_id]);
        await client.query("UPDATE motoristas SET caminhao_ativo_id = $1 WHERE id = $2", [caminhao_id, motorista_id]);
        await client.query('COMMIT');
        res.json({ message: 'Caminhão selecionado com sucesso!' });
    } catch (e) {
        await client.query('ROLLBACK');
        res.status(500).json({ error: e.message });
    } finally {
        client.release();
    }
});

// ROTA DE DISPONIBILIDADE DO MOTORISTA
app.post('/api/motorista/disponibilidade', authenticateToken, async (req, res) => {
    const { disponivel } = req.body;
    const mot_id = req.user.id;
    try {
        await pool.query(
            'UPDATE motoristas SET status_disponibilidade = $1 WHERE id = $2',
            [disponivel, mot_id]
        );
        res.json({ msg: disponivel ? 'Motorista disponível' : 'Motorista indisponível' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// FOTO DE PERFIL DO MOTORISTA
// Reaproveita exatamente o mesmo mecanismo de upload (multer) já usado na
// foto do documento do caminhão. Salva o arquivo em public/uploads/ e grava
// a URL pública na coluna foto_perfil_path — a mesma coluna que o login e o
// /api/motorista/perfil já leem, então não precisa de ALTER TABLE nem de
// nenhuma outra alteração no banco.
// =========================================================================
app.post('/api/motorista/foto-perfil', authenticateToken, upload.single('foto'), async (req, res) => {
    const mot_id = req.user.id;
    try {
        if (!req.file) return res.status(400).json({ error: 'Nenhuma foto enviada.' });

        const fotoUrl = await uploadParaCloudinary(req.file.buffer, 'taclog/foto_perfil', 'image');
        await pool.query('UPDATE motoristas SET foto_perfil_path = $1 WHERE id = $2', [fotoUrl, mot_id]);

        res.json({ message: 'Foto de perfil atualizada com sucesso!', foto_url: fotoUrl });
    } catch (e) {
        console.error('Erro ao salvar foto de perfil:', e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// MATCHMAKING BLINDADO COM TRAVA EXCLUSIVA DE OFERTA
// AJUSTADO PARA CADASTRO V2: consulta a view `conjuntos_ativos` em vez de
// `caminhoes` diretamente. Para caminhões RIGIDO, o tipo_veiculo_efetivo é
// idêntico ao tipo_veiculo de sempre (zero mudança de comportamento). Para
// CAVALO_MECANICO, o tipo vem da carreta acoplada — e se não houver
// carreta acoplada, tipo_veiculo_efetivo vem NULL e o motorista
// automaticamente não entra no match (nada bate com NULL).
//
// Cargas com preferencia_frota_propria = true e frota_tentativa_realizada
// = false ainda NÃO entram nesse matchmaking normal — elas ficam reservadas
// para o scheduler verificarPreferenciaFrota() tentar achar um motorista da
// frota própria primeiro. Só depois de tentado (ou se não tiver preferência
// de frota) é que a carga fica disponível aqui, para qualquer TAC autônomo.
// =========================================================================
app.get('/api/motorista/ofertas-pendentes', authenticateToken, async (req, res) => {
    const mot_id = req.user.id;
    const client = await pool.connect();
    try { 
        await client.query(`
            DELETE FROM ofertas_frete 
            WHERE status = 'ENVIADA' 
            AND data_criacao < now() - interval '30 seconds'
        `);

        const cam = await client.query(`
            SELECT ca.tipo_veiculo_efetivo AS tipo_veiculo
            FROM motoristas m 
            JOIN conjuntos_ativos ca ON m.caminhao_ativo_id = ca.caminhao_id
            WHERE m.id = $1
        `, [mot_id]);
        
        if (cam.rows.length === 0 || !cam.rows[0].tipo_veiculo) return res.json([]); 
        const tipo_caminhao = cam.rows[0].tipo_veiculo;

        // =====================================================================
        // NOVO: checa primeiro se o motorista já tem uma carga EM_ANDAMENTO ou
        // COLETADA — cobre tanto o caso de designação direta (funcionário de
        // transportadora, que nunca passa pela etapa de oferta) quanto o caso
        // geral de recuperar o estado da viagem se o app foi reaberto no meio
        // do trajeto. Nesses casos, devolve a carga já com o "estado_viagem"
        // certo, pulando a tela de Aceitar/Recusar.
        // =====================================================================
        const viagemAtiva = await client.query(`
            SELECT * FROM cargas WHERE motorista_id = $1 AND status IN ('EM_ANDAMENTO', 'COLETADA')
        `, [mot_id]);
        if (viagemAtiva.rows.length > 0) {
            const carga = viagemAtiva.rows[0];
            return res.json([{ ...carga, estado_viagem: carga.status === 'COLETADA' ? 'COLETADA' : 'ACEITA' }]);
        }

        const ofertaAtiva = await client.query(`
            SELECT of.carga_id 
            FROM ofertas_frete of
            WHERE of.motorista_id = $1 
            AND of.status = 'ENVIADA'
        `, [mot_id]);

        if (ofertaAtiva.rows.length > 0) {
            const cargaResult = await client.query(`
                SELECT * FROM cargas WHERE id = $1 AND status = 'DISPONIVEL'
            `, [ofertaAtiva.rows[0].carga_id]);
            return res.json(cargaResult.rows);
        }

        const result = await client.query(`
            SELECT C.*
            FROM cargas C
            WHERE C.status = 'DISPONIVEL'
              AND (C.preferencia_frota_propria IS NOT TRUE OR C.frota_tentativa_realizada = true)
              AND TRIM(UPPER(C.tipo_veiculo_necessario)) = TRIM(UPPER($1))
              AND C.id NOT IN (
                  SELECT carga_id FROM ofertas_frete 
                  WHERE motorista_id = $2 
                  AND status IN ('REJEITADA', 'CANCELADA_EMBARCADOR')
              )
              AND NOT EXISTS (
                  SELECT 1 FROM ofertas_frete of2
                  WHERE of2.carga_id = C.id
                  AND of2.status IN ('ENVIADA', 'AGUARDANDO_TRANSPORTADORA')
              )
              AND $2 = (
                  SELECT loc.motorista_id
                  FROM localizacao_atual loc
                  JOIN motoristas m ON loc.motorista_id = m.id
                  JOIN conjuntos_ativos cam ON m.caminhao_ativo_id = cam.caminhao_id
                  WHERE TRIM(UPPER(cam.tipo_veiculo_efetivo)) = TRIM(UPPER(C.tipo_veiculo_necessario))
                    AND m.status_disponibilidade = true
                    AND m.vinculo = 'AUTONOMO'
                    AND NOT EXISTS (
                        SELECT 1 FROM ofertas_frete ofr 
                        WHERE ofr.carga_id = C.id 
                          AND ofr.motorista_id = m.id 
                          AND ofr.status IN ('REJEITADA', 'CANCELADA_EMBARCADOR')
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM cargas c2
                        WHERE c2.motorista_id = m.id
                          AND c2.status IN ('EM_ANDAMENTO', 'COLETADA')
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM ofertas_frete of3
                        WHERE of3.motorista_id = m.id
                        AND of3.status IN ('ENVIADA', 'AGUARDANDO_TRANSPORTADORA')
                    )
                    AND loc.timestamp_atualizacao > now() - interval '2 minutes'
                  ORDER BY 
                    CASE WHEN C.lat_coleta IS NOT NULL AND loc.ponto IS NOT NULL 
                         THEN ST_Distance(loc.ponto, ST_SetSRID(ST_MakePoint(C.lng_coleta, C.lat_coleta), 4326)::geography) 
                         ELSE 0 END ASC,
                    m.id ASC
                  LIMIT 1
              )
            ORDER BY C.id DESC LIMIT 1
        `, [tipo_caminhao, mot_id]);

        if (result.rows.length > 0) {
            const carga_id = result.rows[0].id;
            await client.query(`
                INSERT INTO ofertas_frete (carga_id, motorista_id, status, data_criacao)
                VALUES ($1, $2, 'ENVIADA', now())
                ON CONFLICT DO NOTHING
            `, [carga_id, mot_id]);
            console.log(`[MATCHMAKING] Oferta TRAVADA: Carga #${carga_id} → Motorista #${mot_id}`);
        }
        
        res.json(result.rows); 
    } catch (e) { 
        console.error("Erro no matchmaking:", e);
        res.status(500).json({ error: e.message }); 
    } finally {
        client.release();
    }
});

// RESPOSTA À OFERTA
app.post('/api/ofertas/responder', authenticateToken, async (req, res) => {
    const { carga_id, aceitou } = req.body;
    const mot_id = req.user.id;
    
    if (!aceitou) {
        try {
            await pool.query(`
                UPDATE ofertas_frete 
                SET status = 'REJEITADA' 
                WHERE carga_id = $1 AND motorista_id = $2 AND status = 'ENVIADA'
            `, [carga_id, mot_id]);

            await pool.query(`
                INSERT INTO ofertas_frete (carga_id, motorista_id, status)
                SELECT $1, $2, 'REJEITADA'
                WHERE NOT EXISTS (
                    SELECT 1 FROM ofertas_frete 
                    WHERE carga_id = $1 AND motorista_id = $2 AND status = 'REJEITADA'
                )
            `, [carga_id, mot_id]);

            console.log(`[MATCHMAKING] Carga #${carga_id} REJEITADA pelo Motorista #${mot_id}. Liberada para o próximo.`);
        } catch (e) { console.error("Erro ao gravar rejeição:", e); }
        return res.json({ msg: 'Recusado' });
    }
    
    try {
        const result = await pool.query(
            "UPDATE cargas SET status = 'EM_ANDAMENTO', motorista_id = $1 WHERE id = $2 AND status = 'DISPONIVEL' RETURNING id", 
            [mot_id, carga_id]
        );
        if (result.rowCount === 0) {
            await pool.query(`
                UPDATE ofertas_frete SET status = 'REJEITADA' 
                WHERE carga_id = $1 AND motorista_id = $2 AND status = 'ENVIADA'
            `, [carga_id, mot_id]);
            return res.status(400).json({ error: 'Carga não está mais disponível.' });
        }

        await pool.query(`
            DELETE FROM ofertas_frete 
            WHERE carga_id = $1 AND motorista_id = $2 AND status = 'ENVIADA'
        `, [carga_id, mot_id]);
        
        const dados = await pool.query(`
            SELECT m.nome, m.cpf, m.rntrc, c.descricao, c.valor_frete, c.valor_pedagio, 
                   c.chave_nfe, c.col_cidade, c.ent_cidade 
            FROM motoristas m, cargas c 
            WHERE m.id = $1 AND c.id = $2
        `, [mot_id, carga_id]);

        if (dados.rows.length > 0) {
            const d = dados.rows[0];
            const nomePdf = `contrato_${carga_id}.pdf`;
            gerarPDF(d, nomePdf);
            console.log(`[MATCHMAKING] Carga #${carga_id} ACEITA pelo Motorista #${mot_id}. Viagem iniciada!`);
            res.json({ message: 'Aceito! Contrato gerado.', pdf: nomePdf });
        } else {
            res.json({ message: 'Aceito! Viagem Iniciada.' });
        }
    } catch (e) { console.error(e); res.status(500).send("Erro"); }
});

// CANCELAMENTO DO MOTORISTA
app.post('/api/cargas/cancelar-motorista', authenticateToken, async (req, res) => {
    const { id } = req.body;
    const mot_id = req.user.id;
    try {
        await pool.query("UPDATE cargas SET status = 'DISPONIVEL', motorista_id = NULL WHERE id = $1 AND motorista_id = $2 AND status = 'EM_ANDAMENTO'", [id, mot_id]);
        await pool.query("INSERT INTO ofertas_frete (carga_id, motorista_id, status) VALUES ($1, $2, 'REJEITADA')", [id, mot_id]);
        res.json({ message: 'Viagem cancelada pelo motorista. Voltando a procurar cargas.' });
    } catch (e) { res.status(500).send("Erro"); }
});

// VERIFICAÇÃO CONTÍNUA DO APP — agora sabe checar tanto cargas do
// Mercado quanto Coletas Próprias, dependendo da origem informada.
// Antes só olhava a tabela `cargas`, e cancelava viagens de Coleta
// Própria sozinho (por engano) achando que "sumiram".
app.get('/api/motorista/carga-atual/:id', authenticateToken, async (req, res) => {
    const { id } = req.params;
    const { origem } = req.query;
    const mot_id = req.user.id;
    try {
        if (origem === 'coleta_propria') {
            const result = await pool.query(`
                SELECT co.status, cam.motorista_atual_id
                FROM coletas_frota co
                LEFT JOIN caminhoes cam ON cam.id = co.caminhao_id
                WHERE co.id = $1
            `, [id]);
            if (result.rows.length === 0) {
                return res.status(404).json({ error: 'CARGA_EXCLUIDA' });
            }
            const coleta = result.rows[0];
            if (coleta.status === 'CANCELADA') {
                return res.status(404).json({ error: 'CARGA_EXCLUIDA' });
            }
            if (coleta.motorista_atual_id !== null && coleta.motorista_atual_id !== mot_id) {
                return res.status(403).json({ error: 'MOTORISTA_ALTERADO' });
            }
            return res.json({ status: coleta.status, motorista_id: coleta.motorista_atual_id });
        }

        const result = await pool.query('SELECT status, motorista_id FROM cargas WHERE id = $1', [id]);
        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'CARGA_EXCLUIDA' });
        }
        const carga = result.rows[0];
        if (carga.motorista_id !== null && carga.motorista_id !== mot_id) {
            return res.status(403).json({ error: 'MOTORISTA_ALTERADO' });
        }
        res.json(carga);
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/motorista/perfil', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query('SELECT * FROM motoristas WHERE id = $1', [req.user.id]);
        res.json(result.rows[0] || {});
    } catch(e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/motorista/perfil', authenticateToken, async (req, res) => {
    const m = req.body;
    try {
        const sql = `
            UPDATE motoristas SET 
                nome=$1, rg=$2, data_nascimento=$3, sexo=$4, estado_civil=$5, nome_mae=$6,
                telefone_celular=$7, telefone_fixo=$8, cep=$9, endereco_rua=$10, endereco_numero=$11,
                endereco_complemento=$12, endereco_bairro=$13, endereco_cidade=$14, endereco_estado=$15,
                cnh_numero=$16, cnh_categoria=$17, cnh_validade=$18, cnh_uf=$19, rntrc=$20, pis=$21,
                banco_codigo=$22, banco_agencia=$23, banco_conta=$24, banco_tipo_conta=$25
            WHERE id=$26
        `;
        await pool.query(sql, [
            m.nome, m.rg, m.data_nascimento, m.sexo, m.estado_civil, m.nome_mae,
            m.telefone_celular, m.telefone_fixo, m.cep, m.endereco_rua, m.endereco_numero,
            m.endereco_complemento, m.endereco_bairro, m.endereco_cidade, m.endereco_estado,
            m.cnh_numero, m.cnh_categoria, m.cnh_validade, m.cnh_uf, m.rntrc, m.pis,
            m.banco_codigo, m.banco_agencia, m.banco_conta, m.banco_tipo_conta,
            req.user.id
        ]);
        res.json({ msg: 'Perfil atualizado' });
    } catch(e) { res.status(500).json({ error: e.message }); }
});

// =========================================================================
// A MÁGICA DO GPS REAL: Gravação de Localização e Histórico de Rota
// =========================================================================
app.post('/api/motorista/localizacao', authenticateToken, async (req, res) => { 
    const { latitude, longitude } = req.body;
    const mot_id = req.user.id;
    try {
        if (!latitude || !longitude) return res.json({ msg: 'Sem GPS' });
        
        const check = await pool.query('SELECT motorista_id FROM localizacao_atual WHERE motorista_id = $1', [mot_id]);
        if (check.rows.length > 0) {
            await pool.query('UPDATE localizacao_atual SET ponto = ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography, timestamp_atualizacao = now() WHERE motorista_id = $3', [longitude, latitude, mot_id]);
        } else {
            await pool.query('INSERT INTO localizacao_atual (motorista_id, ponto, timestamp_atualizacao) VALUES ($1, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography, now())', [mot_id, longitude, latitude]);
        }

        await pool.query('INSERT INTO historico_localizacao (motorista_id, ponto, data_hora) VALUES ($1, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography, now())', [mot_id, longitude, latitude]);

        res.json({ msg: 'Localização atualizada e gravada no histórico' }); 
    } catch(e) {
        console.error("Erro na localização:", e);
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/cargas/coletar', authenticateToken, async (req, res) => { 
    await pool.query("UPDATE cargas SET status = 'COLETADA' WHERE id = $1 AND motorista_id = $2", [req.body.id, req.user.id]); 
    res.json({ msg: 'Coletada' }); 
});

app.post('/api/cargas/finalizar', authenticateToken, async (req, res) => { 
    const { id, lat, lng } = req.body;
    await pool.query(
        "UPDATE cargas SET status = 'ENTREGUE', data_hora_finalizacao = now(), lat_finalizacao = $1, lng_finalizacao = $2 WHERE id = $3 AND motorista_id = $4", 
        [lat, lng, id, req.user.id]
    ); 
    res.json({ msg: 'Finalizada' }); 
});

function gerarPDF(d, nome) {
    const doc = new PDFDocument();
    const pasta = path.join(__dirname, 'public', 'contratos');
    if (!fs.existsSync(pasta)) fs.mkdirSync(pasta, { recursive: true });
    doc.pipe(fs.createWriteStream(path.join(pasta, nome)));
    doc.fontSize(20).text('CONTRATO DE FRETE TACLOG', { align: 'center' });
    doc.end();
}

// =========================================================================
// SCHEDULER: verifica a cada 30 segundos se alguma carga AGENDADA já
// atingiu o horário de disparo previsto (data/hora da coleta menos a
// antecedência escolhida pelo embarcador). Quando atinge, muda o status
// para DISPONIVEL, liberando a carga para o matchmaking normal.
// =========================================================================
async function verificarCargasAgendadas() {
    try {
        const result = await pool.query(`
            UPDATE cargas
            SET status = 'DISPONIVEL', disparo_realizado = true
            WHERE status = 'AGENDADA'
              AND disparo_realizado = false
              AND data_hora_disparo_prevista <= now()
            RETURNING id
        `);
        if (result.rows.length > 0) {
            console.log(`[SCHEDULER] ${result.rows.length} carga(s) liberada(s) para matchmaking: #${result.rows.map(r => r.id).join(', #')}`);
        }
    } catch (e) {
        console.error('[SCHEDULER] Erro ao verificar cargas agendadas:', e.message);
    }
}
setInterval(verificarCargasAgendadas, 30000);

// =========================================================================
// SCHEDULER: PREFERÊNCIA DE FROTA PRÓPRIA
// AJUSTADO PARA CADASTRO V2: usa `conjuntos_ativos` (tipo_veiculo_efetivo)
// em vez de `caminhoes.tipo_veiculo` direto, pra funcionar também com
// cavalo mecânico + carreta acoplada dentro da frota.
// Roda a cada 15 segundos. Para cada carga DISPONIVEL com
// preferencia_frota_propria = true e frota_tentativa_realizada = false,
// procura o motorista da frota da própria transportadora (mesmo
// embarcador_id, mesmo tipo de veículo, disponível, com GPS recente) mais
// próximo da coleta. Se achar dentro da distância máxima configurada,
// envia a oferta só para ele (trava exclusiva, igual ao matchmaking
// normal). Se não achar (ninguém da frota, ou só longe demais), grava uma
// notificação para o embarcador e libera a carga para o matchmaking normal
// com TACs autônomos.
// =========================================================================
// =========================================================================
// FUNCIONÁRIO x AUTÔNOMO — decide se a carga vira uma OFERTA normal
// (Aceitar/Recusar, prazo de 30s — motorista autônomo, ou funcionário de
// OUTRA empresa) ou uma DESIGNAÇÃO DIRETA (sem escolha — motorista é
// FUNCIONÁRIO da MESMA transportadora que está publicando a carga: ele
// não decide se vai, é o trabalho dele).
//
// Retorna true se designou direto, false se criou oferta normal — quem
// chama usa isso só pra log/mensagem, o efeito já foi aplicado aqui.
// =========================================================================
async function designarOuOfertar(cargaId, motoristaId, embarcadorId, descricaoCarga) {
    const motorista = await pool.query(
        'SELECT vinculo, embarcador_empregador_id, nome FROM motoristas WHERE id = $1',
        [motoristaId]
    );
    const ehFuncionarioDestaTransportadora =
        motorista.rows.length > 0 &&
        motorista.rows[0].vinculo === 'FUNCIONARIO' &&
        motorista.rows[0].embarcador_empregador_id === embarcadorId;

    if (ehFuncionarioDestaTransportadora) {
        // Designação direta: a carga já é dele, sem etapa de aceite.
        await pool.query(
            `UPDATE cargas SET motorista_id = $1, status = 'EM_ANDAMENTO' WHERE id = $2`,
            [motoristaId, cargaId]
        );
        await pool.query(
            `INSERT INTO notificacoes_motorista (motorista_id, mensagem) VALUES ($1, $2)`,
            [motoristaId, `Carga #${cargaId} designada pra você — ${descricaoCarga || 'sem descrição'}. Acesse "Minha Carga Atual" pra ver os detalhes.`]
        );
        // NOVO: as gestoras também ficam sabendo quem recebeu a carga.
        await avisarGestores(
            embarcadorId,
            `Carga #${cargaId} designada ao motorista ${motorista.rows[0].nome || ''} — ${descricaoCarga || 'sem descrição'}.`,
            'GERAL', cargaId, 'mercado', 'Carga designada'
        );
        return true;
    }

    // Motorista autônomo (ou funcionário de outra empresa, caso raro):
    // segue o fluxo normal de oferta com prazo, igual sempre foi.
    await pool.query(`
        INSERT INTO ofertas_frete (carga_id, motorista_id, status, data_criacao)
        VALUES ($1, $2, 'ENVIADA', now())
        ON CONFLICT DO NOTHING
    `, [cargaId, motoristaId]);
    return false;
}

async function verificarPreferenciaFrota() {
    try {
        const cargas = await pool.query(`
            SELECT c.*, e.distancia_maxima_frota_km
            FROM cargas c
            JOIN embarcadores e ON e.id = c.embarcador_id
            WHERE c.status = 'DISPONIVEL'
              AND c.preferencia_frota_propria = true
              AND c.frota_tentativa_realizada = false
        `);

        for (const carga of cargas.rows) {
            // =================================================================
            // CAMINHO NOVO: caminhão escolhido manualmente pela transportadora.
            // Pula a busca por proximidade e vai direto no motorista que está
            // dirigindo esse caminhão hoje. Revalida a carreta acoplada aqui
            // também (pode ter sido desacoplada entre o momento em que a
            // carga foi criada e agora).
            // =================================================================
            if (carga.caminhao_designado_id) {
                const caminhao = await pool.query(`
                    SELECT cam.id, cam.placa, cam.motorista_atual_id, cam.tipo_unidade_tratora, a.carreta_id
                    FROM caminhoes cam
                    LEFT JOIN acoplamentos a ON a.caminhao_id = cam.id AND a.data_fim IS NULL
                    WHERE cam.id = $1
                `, [carga.caminhao_designado_id]);

                const cam = caminhao.rows[0];
                const semAcoplamentoValido = cam && cam.tipo_unidade_tratora === 'CAVALO_MECANICO' && !cam.carreta_id;

                if (!cam || !cam.motorista_atual_id || semAcoplamentoValido) {
                    const motivo = !cam
                        ? 'o caminhão designado não existe mais'
                        : semAcoplamentoValido
                            ? 'a carreta foi desacoplada do caminhão designado'
                            : 'nenhum motorista está com o caminhão designado no momento';
                    await pool.query(`
                        INSERT INTO notificacoes_embarcador (embarcador_id, carga_id, mensagem)
                        VALUES ($1, $2, $3)
                    `, [carga.embarcador_id, carga.id, `Não foi possível enviar a carga #${carga.id} ao caminhão designado (${motivo}). A carga foi liberada para motoristas autônomos.`]);
                    await pool.query('UPDATE cargas SET frota_tentativa_realizada = true WHERE id = $1', [carga.id]);
                    console.log(`[FROTA] Carga #${carga.id}: caminhão designado indisponível (${motivo}). Liberada para TAC.`);
                    continue;
                }

                const jaOcupado = await pool.query(`
                    SELECT 1 FROM cargas c2 WHERE c2.motorista_id = $1 AND c2.status IN ('EM_ANDAMENTO', 'COLETADA')
                `, [cam.motorista_atual_id]);

                if (jaOcupado.rows.length > 0) {
                    await pool.query(`
                        INSERT INTO notificacoes_embarcador (embarcador_id, carga_id, mensagem)
                        VALUES ($1, $2, $3)
                    `, [carga.embarcador_id, carga.id, `O caminhão ${cam.placa}, designado para a carga #${carga.id}, já está em outra viagem no momento. A carga foi liberada para motoristas autônomos.`]);
                    await pool.query('UPDATE cargas SET frota_tentativa_realizada = true WHERE id = $1', [carga.id]);
                    console.log(`[FROTA] Carga #${carga.id}: caminhão designado ${cam.placa} já ocupado. Liberada para TAC.`);
                    continue;
                }

                const foiDesignacaoDireta = await designarOuOfertar(carga.id, cam.motorista_atual_id, carga.embarcador_id, carga.descricao);
                await pool.query('UPDATE cargas SET frota_tentativa_realizada = true WHERE id = $1', [carga.id]);
                console.log(`[FROTA] Carga #${carga.id}: ${foiDesignacaoDireta ? 'designada direto (funcionário)' : 'oferta enviada'} ao caminhão designado ${cam.placa} (motorista #${cam.motorista_atual_id})`);
                continue;
            }

            // =================================================================
            // CAMINHO EXISTENTE: busca automática pelo caminhão da frota mais
            // próximo (sem designação manual).
            // =================================================================
            const candidatos = await pool.query(`
                SELECT m.id as motorista_id,
                    CASE WHEN $1::numeric IS NOT NULL AND $2::numeric IS NOT NULL AND loc.ponto IS NOT NULL
                         THEN ST_Distance(loc.ponto, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) / 1000.0
                         ELSE NULL END as distancia_km
                FROM motoristas m
                JOIN conjuntos_ativos cam ON m.caminhao_ativo_id = cam.caminhao_id
                JOIN localizacao_atual loc ON loc.motorista_id = m.id
                WHERE cam.embarcador_proprietario_id = $3
                  AND TRIM(UPPER(cam.tipo_veiculo_efetivo)) = TRIM(UPPER($4))
                  AND m.status_disponibilidade = true
                  AND loc.timestamp_atualizacao > now() - interval '2 minutes'
                  AND NOT EXISTS (
                      SELECT 1 FROM cargas c2 WHERE c2.motorista_id = m.id AND c2.status IN ('EM_ANDAMENTO', 'COLETADA')
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ofertas_frete ofr WHERE ofr.motorista_id = m.id AND ofr.status = 'ENVIADA'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ofertas_frete ofr2 WHERE ofr2.carga_id = $5 AND ofr2.motorista_id = m.id AND ofr2.status IN ('REJEITADA', 'CANCELADA_EMBARCADOR')
                  )
                ORDER BY distancia_km ASC NULLS LAST
                LIMIT 1
            `, [carga.lat_coleta, carga.lng_coleta, carga.embarcador_id, carga.tipo_veiculo_necessario, carga.id]);

            if (candidatos.rows.length > 0) {
                const candidato = candidatos.rows[0];
                const distanciaMaxima = parseFloat(carga.distancia_maxima_frota_km) || 0;
                const dentroDoLimite = distanciaMaxima === 0 || candidato.distancia_km === null || candidato.distancia_km <= distanciaMaxima;

                if (dentroDoLimite) {
                    const foiDesignacaoDireta = await designarOuOfertar(carga.id, candidato.motorista_id, carga.embarcador_id, carga.descricao);
                    await pool.query('UPDATE cargas SET frota_tentativa_realizada = true WHERE id = $1', [carga.id]);
                    console.log(`[FROTA] Carga #${carga.id}: ${foiDesignacaoDireta ? 'designada direto (funcionário)' : 'oferta enviada'} ao motorista da frota #${candidato.motorista_id}`);
                } else {
                    await pool.query(`
                        INSERT INTO notificacoes_embarcador (embarcador_id, carga_id, mensagem)
                        VALUES ($1, $2, $3)
                    `, [
                        carga.embarcador_id, carga.id,
                        `O caminhão da sua frota mais próximo está a ${candidato.distancia_km.toFixed(1)} km da coleta da carga #${carga.id}, acima do limite configurado (${distanciaMaxima} km). A carga foi liberada para motoristas autônomos.`
                    ]);
                    await pool.query('UPDATE cargas SET frota_tentativa_realizada = true WHERE id = $1', [carga.id]);
                    console.log(`[FROTA] Carga #${carga.id}: caminhão da frota fora do limite (${candidato.distancia_km.toFixed(1)}km > ${distanciaMaxima}km). Liberada para TAC.`);
                }
            } else {
                await pool.query(`
                    INSERT INTO notificacoes_embarcador (embarcador_id, carga_id, mensagem)
                    VALUES ($1, $2, $3)
                `, [
                    carga.embarcador_id, carga.id,
                    `Nenhum caminhão da sua frota está disponível ou próximo para a carga #${carga.id}. A carga foi liberada para motoristas autônomos.`
                ]);
                await pool.query('UPDATE cargas SET frota_tentativa_realizada = true WHERE id = $1', [carga.id]);
                console.log(`[FROTA] Carga #${carga.id}: nenhum motorista de frota disponível. Liberada para TAC.`);
            }
        }
    } catch (e) {
        console.error('[FROTA] Erro ao verificar preferência de frota:', e.message);
    }
}
setInterval(verificarPreferenciaFrota, 15000);

// =========================================================================
// MERCADO ABERTO PARA A FROTA DE TERCEIROS
// Quando uma transportadora liga "permite_ofertas_mercado_frota" (tela de
// Configurações), os caminhões OCIOSOS da sua frota (motoristas
// FUNCIONARIO) passam a concorrer também pelas cargas do MERCADO ABERTO
// (de qualquer embarcador, não só da própria transportadora).
//
// A diferença pro fluxo do TAC autônomo: a oferta não vai direto pro
// motorista. Ela fica com status 'AGUARDANDO_TRANSPORTADORA' até a
// própria transportadora aprovar ou recusar, pela tela "Ofertas do
// Mercado". Só depois de aprovada é que vira uma oferta normal
// ('ENVIADA') pro motorista, com o mesmo fluxo de Aceitar/Recusar (30s)
// de sempre. Se a transportadora recusar, ou não responder em 3 minutos,
// a oferta é liberada pro próximo candidato — o motorista nunca fica
// sabendo que ela existiu.
//
// Roda a cada 15 segundos, igual ao scheduler de frota própria.
// =========================================================================
async function verificarOfertasMercadoFrota() {
    try {
        // Expira pedidos de aprovação parados há mais de 3 minutos sem
        // resposta da transportadora — libera a carga pro próximo
        // candidato (outro caminhão de frota ou um TAC autônomo).
        const expiradas = await pool.query(`
            UPDATE ofertas_frete
            SET status = 'REJEITADA'
            WHERE status = 'AGUARDANDO_TRANSPORTADORA'
              AND data_criacao < now() - interval '3 minutes'
            RETURNING carga_id, motorista_id
        `);
        for (const row of expiradas.rows) {
            console.log(`[MERCADO-FROTA] Oferta da carga #${row.carga_id} pro motorista #${row.motorista_id} expirou sem resposta da transportadora. Liberada.`);
        }

        const cargas = await pool.query(`
            SELECT c.*
            FROM cargas c
            WHERE c.status = 'DISPONIVEL'
              AND (c.preferencia_frota_propria IS NOT TRUE OR c.frota_tentativa_realizada = true)
              AND NOT EXISTS (
                  SELECT 1 FROM ofertas_frete of2
                  WHERE of2.carga_id = c.id AND of2.status IN ('ENVIADA', 'AGUARDANDO_TRANSPORTADORA')
              )
        `);

        for (const carga of cargas.rows) {
            const candidato = await pool.query(`
                SELECT m.id as motorista_id, cam.embarcador_proprietario_id as transportadora_id,
                    cam.placa,
                    CASE WHEN $1::numeric IS NOT NULL AND $2::numeric IS NOT NULL AND loc.ponto IS NOT NULL
                         THEN ST_Distance(loc.ponto, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) / 1000.0
                         ELSE NULL END as distancia_km
                FROM motoristas m
                JOIN conjuntos_ativos cam ON m.caminhao_ativo_id = cam.caminhao_id
                JOIN localizacao_atual loc ON loc.motorista_id = m.id
                JOIN embarcadores emp ON emp.id = cam.embarcador_proprietario_id
                WHERE m.vinculo = 'FUNCIONARIO'
                  AND emp.permite_ofertas_mercado_frota = true
                  AND cam.embarcador_proprietario_id <> $3
                  AND TRIM(UPPER(cam.tipo_veiculo_efetivo)) = TRIM(UPPER($4))
                  AND m.status_disponibilidade = true
                  AND loc.timestamp_atualizacao > now() - interval '2 minutes'
                  AND NOT EXISTS (
                      SELECT 1 FROM cargas c2 WHERE c2.motorista_id = m.id AND c2.status IN ('EM_ANDAMENTO', 'COLETADA')
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ofertas_frete ofr WHERE ofr.motorista_id = m.id AND ofr.status IN ('ENVIADA', 'AGUARDANDO_TRANSPORTADORA')
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM ofertas_frete ofr2 WHERE ofr2.carga_id = $5 AND ofr2.motorista_id = m.id AND ofr2.status IN ('REJEITADA', 'CANCELADA_EMBARCADOR')
                  )
                ORDER BY distancia_km ASC NULLS LAST
                LIMIT 1
            `, [carga.lat_coleta, carga.lng_coleta, carga.embarcador_id, carga.tipo_veiculo_necessario, carga.id]);

            if (candidato.rows.length === 0) continue;

            const cand = candidato.rows[0];
            await pool.query(`
                INSERT INTO ofertas_frete (carga_id, motorista_id, status, data_criacao)
                VALUES ($1, $2, 'AGUARDANDO_TRANSPORTADORA', now())
                ON CONFLICT DO NOTHING
            `, [carga.id, cand.motorista_id]);

            await pool.query(`
                INSERT INTO notificacoes_embarcador (embarcador_id, carga_id, mensagem)
                VALUES ($1, $2, $3)
            `, [
                cand.transportadora_id, carga.id,
                `Nova oferta do mercado disponível para o caminhão ${cand.placa || ''} (motorista #${cand.motorista_id}): carga #${carga.id}, ${carga.tipo_veiculo_necessario || ''} — ${carga.col_cidade || '?'}/${carga.col_uf || '?'} → ${carga.ent_cidade || '?'}/${carga.ent_uf || '?'}. Acesse "Ofertas do Mercado" para aceitar ou recusar.`
            ]);

            console.log(`[MERCADO-FROTA] Carga #${carga.id} oferecida (aguardando aprovação) ao caminhão ${cand.placa} da transportadora #${cand.transportadora_id}, motorista #${cand.motorista_id}.`);
        }
    } catch (e) {
        console.error('[MERCADO-FROTA] Erro ao verificar ofertas de mercado para frota:', e.message);
    }
}
setInterval(verificarOfertasMercadoFrota, 15000);

// =========================================================================
// MERCADO ABERTO PARA FROTA — TRANSPORTADORA APROVA/RECUSA
// Lista as ofertas do mercado aberto que verificarOfertasMercadoFrota()
// já pré-selecionou para os caminhões desta transportadora, e permite
// aprovar (vira oferta normal pro motorista) ou recusar (libera pro
// próximo candidato).
// =========================================================================
app.get('/api/transportadora/ofertas-mercado', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT ofr.id as oferta_id, ofr.carga_id, ofr.motorista_id, ofr.data_criacao,
                   c.descricao, c.tipo_veiculo_necessario, c.valor_frete,
                   c.col_cidade, c.col_uf, c.ent_cidade, c.ent_uf, c.data_coleta,
                   m.nome as motorista_nome, cam.placa as caminhao_placa
            FROM ofertas_frete ofr
            JOIN cargas c ON c.id = ofr.carga_id
            JOIN motoristas m ON m.id = ofr.motorista_id
            LEFT JOIN caminhoes cam ON cam.id = m.caminhao_ativo_id
            WHERE ofr.status = 'AGUARDANDO_TRANSPORTADORA'
              AND m.embarcador_empregador_id = $1
            ORDER BY ofr.data_criacao ASC
        `, [req.user.id]);
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/transportadora/ofertas-mercado/:id/responder', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const { aceitou } = req.body;
    try {
        const check = await pool.query(`
            SELECT ofr.id, ofr.carga_id, ofr.motorista_id
            FROM ofertas_frete ofr
            JOIN motoristas m ON m.id = ofr.motorista_id
            WHERE ofr.id = $1 AND ofr.status = 'AGUARDANDO_TRANSPORTADORA' AND m.embarcador_empregador_id = $2
        `, [id, req.user.id]);

        if (check.rows.length === 0) {
            return res.status(404).json({ error: 'Oferta não encontrada, já respondida, ou não pertence à sua frota.' });
        }

        const oferta = check.rows[0];

        if (aceitou === true) {
            // Vira uma oferta normal pro motorista, com os mesmos 30s de
            // sempre pra aceitar/recusar — reinicia o relógio a partir de
            // agora, que é quando ele efetivamente fica sabendo dela.
            await pool.query(`
                UPDATE ofertas_frete SET status = 'ENVIADA', data_criacao = now() WHERE id = $1
            `, [oferta.id]);
            console.log(`[MERCADO-FROTA] Transportadora #${req.user.id} APROVOU a carga #${oferta.carga_id} pro motorista #${oferta.motorista_id}. Enviada pro app dele.`);
            res.json({ message: 'Oferta aprovada! Enviada para o motorista.' });
        } else {
            await pool.query(`UPDATE ofertas_frete SET status = 'REJEITADA' WHERE id = $1`, [oferta.id]);
            console.log(`[MERCADO-FROTA] Transportadora #${req.user.id} RECUSOU a carga #${oferta.carga_id} pro motorista #${oferta.motorista_id}. Liberada.`);
            res.json({ message: 'Oferta recusada.' });
        }
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// MÓDULO NOVO: CLIENTES DA TRANSPORTADORA (remetente/destinatário reutilizável)
// Exclusivo de embarcadores com is_transportadora = true. Cada cliente
// cadastrado pode ser usado como remetente numa coleta e destinatário em
// outra — o papel é decidido na hora de criar a coleta.
// =========================================================================
const CAMPOS_CLIENTE_PERMITIDOS = [
    'tipo_pessoa', 'nome_razao_social', 'nome_fantasia', 'cpf_cnpj', 'inscricao_estadual',
    'contato_nome', 'telefone', 'email', 'cep', 'rua', 'numero', 'complemento', 'bairro', 'cidade', 'uf', 'lat', 'lng'
];

app.get('/api/transportadora/clientes', authenticateToken, exigirTransportadora, async (req, res) => {
    // FILTROS (todos opcionais): busca (nome, fantasia ou CPF/CNPJ - mesmo
    // com pontos/traço), cidade, uf, operacao_de / operacao_ate (AAAA-MM-DD).
    // PAGINAÇÃO (opcional): se vier "pagina", devolve
    //   { itens, total, pagina, limite, total_paginas }
    // com no máximo "limite" clientes (padrão 50, teto 200) - é o que a tela
    // de Clientes usa, pra não carregar milhares de linhas de uma vez.
    // Sem "pagina", mantém o comportamento antigo (lista completa), que as
    // telas de coleta ainda usam pra selecionar cliente.
    const { busca, cidade, uf, operacao_de, operacao_ate } = req.query;
    const paginado = req.query.pagina !== undefined;
    try {
        // data_ultima_operacao: a data mais recente em que uma coleta_frota
        // já foi de fato executada pra esse cliente - conta como remetente
        // (coleta) quando o status já passou de AGENDADA (COLETADA,
        // EM_TRANSITO ou ENTREGUE - ou seja, o caminhão já passou lá), e
        // como destinatário (entrega) só quando ENTREGUE (a carga já
        // chegou de verdade). CANCELADA nunca conta. Isso alimenta tanto a
        // coluna "Última Coleta/Entrega" quanto o filtro por intervalo de
        // datas na tela de Clientes.
        const ultimaOperacao = (alias) => `(
                SELECT MAX(d) FROM (
                    SELECT data_coleta AS d FROM coletas_frota
                    WHERE remetente_id = ${alias}.id AND status IN ('COLETADA', 'EM_TRANSITO', 'ENTREGUE')
                    UNION ALL
                    SELECT COALESCE(data_entrega_prevista, data_coleta) AS d FROM coletas_frota
                    WHERE destinatario_id = ${alias}.id AND status = 'ENTREGUE'
                ) datas_operacao
            )`;

        const params = [req.user.id];
        let where = `c.embarcador_id = $1 AND c.ativo = TRUE`;
        const escaparLike = (t) => t.replace(/[\\%_]/g, '\\$&');

        if (busca && String(busca).trim() !== '') {
            const termo = String(busca).trim();
            params.push(`%${escaparLike(termo)}%`);
            let cond = `c.nome_razao_social ILIKE $${params.length} OR c.nome_fantasia ILIKE $${params.length}`;
            const digitos = termo.replace(/\D/g, '');
            if (digitos !== '') {
                params.push(`%${digitos}%`);
                cond += ` OR regexp_replace(COALESCE(c.cpf_cnpj, ''), '\\D', '', 'g') LIKE $${params.length}`;
            }
            where += ` AND (${cond})`;
        }
        if (cidade && String(cidade).trim() !== '') {
            params.push(`%${escaparLike(String(cidade).trim())}%`);
            where += ` AND c.cidade ILIKE $${params.length}`;
        }
        if (uf && String(uf).trim() !== '') {
            params.push(String(uf).trim().toUpperCase());
            where += ` AND UPPER(TRIM(c.uf)) = $${params.length}`;
        }
        const dataValida = (d) => typeof d === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(d);
        if (dataValida(operacao_de)) {
            params.push(operacao_de);
            where += ` AND (${ultimaOperacao('c')})::date >= $${params.length}::date`;
        }
        if (dataValida(operacao_ate)) {
            params.push(operacao_ate);
            where += ` AND (${ultimaOperacao('c')})::date <= $${params.length}::date`;
        }

        if (!paginado) {
            const result = await pool.query(
                `SELECT c.*, ${ultimaOperacao('c')} AS data_ultima_operacao
                 FROM clientes_transportadora c
                 WHERE ${where}
                 ORDER BY LOWER(c.nome_razao_social) ASC, c.id ASC`,
                params
            );
            return res.json(result.rows);
        }

        const limite = Math.min(Math.max(parseInt(req.query.limite, 10) || 50, 1), 200);
        const pagina = Math.max(parseInt(req.query.pagina, 10) || 1, 1);
        const offset = (pagina - 1) * limite;

        // A "última operação" só é calculada para as linhas da página
        // (subconsulta externa), não para a base inteira.
        const [lista, contagem] = await Promise.all([
            pool.query(
                `SELECT p.*, ${ultimaOperacao('p')} AS data_ultima_operacao
                 FROM (
                    SELECT c.* FROM clientes_transportadora c
                    WHERE ${where}
                    ORDER BY LOWER(c.nome_razao_social) ASC, c.id ASC
                    LIMIT ${limite} OFFSET ${offset}
                 ) p
                 ORDER BY LOWER(p.nome_razao_social) ASC, p.id ASC`,
                params
            ),
            pool.query(`SELECT COUNT(*)::int AS total FROM clientes_transportadora c WHERE ${where}`, params),
        ]);
        const total = contagem.rows[0].total;
        res.json({
            itens: lista.rows,
            total,
            pagina,
            limite,
            total_paginas: Math.max(Math.ceil(total / limite), 1),
        });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/transportadora/clientes', authenticateToken, exigirTransportadora, async (req, res) => {
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        if (!c.nome_razao_social || c.nome_razao_social.trim() === '') {
            return res.status(400).json({ error: 'Nome/Razão Social é obrigatório.' });
        }
        const camposEnviados = CAMPOS_CLIENTE_PERMITIDOS.filter(campo => c[campo] !== undefined && c[campo] !== '');
        const colunas = ['embarcador_id', ...camposEnviados];
        const valores = [embarcador_id, ...camposEnviados.map(campo => c[campo])];
        const placeholders = valores.map((_, i) => `$${i + 1}`).join(', ');

        const sql = `INSERT INTO clientes_transportadora (${colunas.join(', ')}) VALUES (${placeholders}) RETURNING *`;
        const result = await pool.query(sql, valores);
        res.status(201).json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/transportadora/clientes/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        const check = await pool.query('SELECT id FROM clientes_transportadora WHERE id = $1 AND embarcador_id = $2', [id, embarcador_id]);
        if (check.rows.length === 0) return res.status(404).json({ error: 'Cliente não encontrado ou sem permissão.' });

        const camposEnviados = CAMPOS_CLIENTE_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });

        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        const result = await pool.query(
            `UPDATE clientes_transportadora SET ${setClause}, atualizado_em = now() WHERE id = $${camposEnviados.length + 1} AND embarcador_id = $${camposEnviados.length + 2} RETURNING *`,
            [...valores, id, embarcador_id]
        );
        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.delete('/api/transportadora/clientes/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const embarcador_id = req.user.id;
    try {
        const result = await pool.query(
            'UPDATE clientes_transportadora SET ativo = FALSE WHERE id = $1 AND embarcador_id = $2 RETURNING id',
            [id, embarcador_id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Cliente não encontrado ou sem permissão.' });
        res.json({ message: 'Cliente removido com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// MÓDULO NOVO: COLETAS DA FROTA PRÓPRIA
// Agendamento de coleta/entrega com atribuição DIRETA de um caminhão (e
// carreta, se for o caso) da frota da transportadora — sem matchmaking,
// a funcionária já escolhe qual veículo vai fazer o trajeto.
// =========================================================================
const CAMPOS_COLETA_PERMITIDOS = [
    'tipo_carga', 'descricao', 'peso_kg', 'altura_m', 'largura_m', 'comprimento_m', 'volume_m3',
    'data_coleta', 'hora_coleta', 'data_entrega_prevista', 'hora_entrega_prevista',
    'tempo_antecedencia_aviso_minutos',
    'remetente_id', 'remetente_nome', 'remetente_cpf_cnpj',
    'remetente_inscricao_estadual', 'remetente_contato_nome', 'remetente_telefone', 'remetente_email',
    'col_cep', 'col_rua', 'col_numero', 'col_complemento', 'col_bairro', 'col_cidade', 'col_uf', 'col_lat', 'col_lng',
    'destinatario_id', 'destinatario_nome', 'destinatario_cpf_cnpj',
    'destinatario_inscricao_estadual', 'destinatario_contato_nome', 'destinatario_telefone', 'destinatario_email',
    'ent_cep', 'ent_rua', 'ent_numero', 'ent_complemento', 'ent_bairro', 'ent_cidade', 'ent_uf', 'ent_lat', 'ent_lng',
    'caminhao_id', 'carreta_id', 'observacoes',
    'valor_frete'
];

// Valor do frete cobrado pela transportadora nesta operação (R$). Obrigatório
// ao agendar (maior que zero) — é a base de informação de preços do TACLOG.
// Aceita número ou texto no formato "1.234,56" / "1234.56".
function normalizarValorFrete(v) {
    if (v === undefined || v === null || v === '') return null;
    if (typeof v === 'number') return Number.isFinite(v) ? v : null;
    let t = String(v).trim().replace(/[R$\s]/g, '');
    if (t.includes(',')) t = t.replace(/\./g, '').replace(',', '.');
    const n = Number(t);
    return Number.isFinite(n) ? n : null;
}

const STATUS_COLETA_VALIDOS = ['AGENDADA', 'EM_COLETA', 'COLETADA', 'EM_TRANSITO', 'ENTREGUE', 'CANCELADA'];

// Confere se o caminhão/carreta informado realmente pertence à frota
// desta transportadora, antes de permitir a atribuição na coleta.
async function validarVeiculoDaFrota(embarcador_id, caminhao_id, carreta_id) {
    if (caminhao_id) {
        const cam = await pool.query(
            'SELECT id FROM caminhoes WHERE id = $1 AND embarcador_proprietario_id = $2',
            [caminhao_id, embarcador_id]
        );
        if (cam.rows.length === 0) return 'Caminhão informado não pertence à sua frota.';
    }
    if (carreta_id) {
        const car = await pool.query(
            'SELECT id FROM carretas WHERE id = $1 AND embarcador_proprietario_id = $2',
            [carreta_id, embarcador_id]
        );
        if (car.rows.length === 0) return 'Carreta informada não pertence à sua frota.';
    }
    return null;
}

// =========================================================================
// GESTORAS (funcionárias de escritório que recebem os avisos de coleta no
// celular). Cada aviso que o sistema manda pro motorista também é copiado
// aqui pra TODAS as gestoras ATIVAS da transportadora (tabela
// notificacoes_gestor), e — como o app só "enxerga" avisos enquanto está
// aberto — também vai uma cópia por e-mail, que toca no celular mesmo com a
// tela bloqueada. Nunca derruba quem chama: qualquer erro só vai pro log.
// =========================================================================
function escaparHtmlAviso(t) {
    return String(t || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function avisarGestores(embarcadorId, mensagem, tipo = 'GERAL', referenciaId = null, referenciaOrigem = null, assuntoEmail = null) {
    if (!embarcadorId || !mensagem) return;
    try {
        const gestoras = await pool.query(
            "SELECT id, nome, email FROM funcionarios_embarcador WHERE embarcador_id = $1 AND status = 'ATIVO' AND recebe_avisos_app = TRUE",
            [embarcadorId]
        );
        for (const g of gestoras.rows) {
            await pool.query(
                'INSERT INTO notificacoes_gestor (funcionario_id, embarcador_id, mensagem, tipo, referencia_id, referencia_origem) VALUES ($1, $2, $3, $4, $5, $6)',
                [g.id, embarcadorId, mensagem, tipo, referenciaId, referenciaOrigem]
            );
            if (g.email) {
                // sem await de propósito: e-mail lento não pode atrasar o scheduler.
                enviarEmailAvisoOperacional(
                    g.email,
                    `TACLOG — ${assuntoEmail || 'Aviso de coleta'}`,
                    `<p>${escaparHtmlAviso(mensagem)}</p>`
                ).catch(e => console.error(`[AVISAR GESTORES] e-mail para ${g.email} falhou:`, e.message));
            }
        }
    } catch (e) {
        console.error('[AVISAR GESTORES] erro:', e.message);
    }
}

// Monta o texto que a gestora lê: o mesmo aviso do motorista, só que
// escrito pra quem acompanha (e com o motorista e a placa no fim).
function montarMensagemGestor(mensagem, tipo, placa, motoristaNome) {
    let texto = String(mensagem || '');
    if (tipo === 'COLETAR_AGORA') {
        texto = 'É a hora da coleta: ' + texto.replace(/^Coletar\s+/i, '');
    }
    const quem = motoristaNome ? `Motorista: ${motoristaNome}` : 'Sem motorista no caminhão';
    const veiculo = placa ? ` — Placa: ${placa}` : '';
    return `${texto} (${quem}${veiculo})`;
}

// Só quem é funcionária ATIVA marcada como gestora entra nas rotas abaixo.
async function exigirGestoraApp(req, res, next) {
    try {
        if (req.user.role !== 'embarcador' || !req.user.funcionario_id) {
            return res.status(403).json({ error: 'GESTOR_SEM_ACESSO', message: 'Este acesso é só para gestoras cadastradas.' });
        }
        const r = await pool.query(
            'SELECT id, nome, status, recebe_avisos_app FROM funcionarios_embarcador WHERE id = $1 AND embarcador_id = $2',
            [req.user.funcionario_id, req.user.id]
        );
        const f = r.rows[0];
        if (!f || f.status !== 'ATIVO' || f.recebe_avisos_app !== true) {
            return res.status(403).json({ error: 'GESTOR_SEM_ACESSO', message: 'Seu acesso a avisos no app não está ativo. Fale com o administrador.' });
        }
        req.gestora = f;
        next();
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
}

app.get('/api/gestor/notificacoes', authenticateToken, exigirGestoraApp, async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT * FROM notificacoes_gestor WHERE funcionario_id = $1 ORDER BY data_criacao DESC, id DESC LIMIT 60',
            [req.gestora.id]
        );
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/gestor/notificacoes/contagem', authenticateToken, exigirGestoraApp, async (req, res) => {
    try {
        const result = await pool.query(
            'SELECT COUNT(*) FROM notificacoes_gestor WHERE funcionario_id = $1 AND lida = false',
            [req.gestora.id]
        );
        res.json({ total_nao_lidas: parseInt(result.rows[0].count) });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/gestor/notificacoes/marcar-todas-lidas', authenticateToken, exigirGestoraApp, async (req, res) => {
    try {
        await pool.query('UPDATE notificacoes_gestor SET lida = true WHERE funcionario_id = $1 AND lida = false', [req.gestora.id]);
        res.json({ message: 'Todas as notificações foram marcadas como lidas.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/gestor/notificacoes/:id/marcar-lida', authenticateToken, exigirGestoraApp, async (req, res) => {
    try {
        const r = await pool.query(
            'UPDATE notificacoes_gestor SET lida = true WHERE id = $1 AND funcionario_id = $2 RETURNING id',
            [req.params.id, req.gestora.id]
        );
        if (r.rows.length === 0) return res.status(404).json({ error: 'Notificação não encontrada.' });
        res.json({ message: 'Notificação marcada como lida.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// NOVO: aviso IMEDIATO de "Carga Agendada" pro motorista assim que a
// transportadora designa um caminhão da frota (na hora de criar/editar o
// agendamento) — separado do aviso de antecedência, que continua
// disparando mais perto da hora da coleta (verificarAvisosColeta /
// verificarPreferenciaFrota). Vale tanto pra Coleta Própria quanto pra
// carga do Mercado com caminhão designado.
async function notificarCaminhaoDesignadoAgora(caminhao_id, mensagem, tipo = 'GERAL', referencia_id = null, referencia_origem = null) {
    if (!caminhao_id) return;
    try {
        const cam = await pool.query(
            `SELECT c.motorista_atual_id, c.placa, c.embarcador_proprietario_id, m.nome AS motorista_nome
             FROM caminhoes c
             LEFT JOIN motoristas m ON m.id = c.motorista_atual_id
             WHERE c.id = $1`,
            [caminhao_id]
        );
        const motoristaId = cam.rows[0]?.motorista_atual_id;
        if (motoristaId) {
            // Isolado de propósito: se o aviso do motorista falhar por algum
            // motivo, a cópia das gestoras (logo abaixo) ainda sai.
            try {
                await pool.query(
                    'INSERT INTO notificacoes_motorista (motorista_id, mensagem, tipo, referencia_id, referencia_origem) VALUES ($1, $2, $3, $4, $5)',
                    [motoristaId, mensagem, tipo, referencia_id, referencia_origem]
                );
            } catch (e) {
                console.error('[NOTIFICAR CAMINHÃO DESIGNADO] erro ao avisar o motorista:', e.message);
            }
        }
        // NOVO: cópia do mesmo aviso pras gestoras da transportadora dona
        // do caminhão (mesmo que o caminhão esteja sem motorista agora).
        if (cam.rows[0]?.embarcador_proprietario_id) {
            await avisarGestores(
                cam.rows[0].embarcador_proprietario_id,
                montarMensagemGestor(mensagem, tipo, cam.rows[0].placa, cam.rows[0].motorista_nome),
                tipo, referencia_id, referencia_origem,
                tipo === 'COLETAR_AGORA' ? 'Hora da coleta' : 'Coleta agendada'
            );
        }
    } catch (e) {
        console.error('[NOTIFICAR CAMINHÃO DESIGNADO] erro:', e.message);
    }
}

// =========================================================================
// SCHEDULER: a cada 30 segundos, verifica se alguma carga do Mercado (já
// designada a um caminhão) ou Coleta Própria atingiu a data/hora exata da
// coleta. Quando atinge, manda uma notificação tipo 'COLETAR_AGORA' (o
// app reconhece esse tipo e mostra um popup com botão de ação, não só
// texto) — diferente do aviso de designação, que já sai na hora de
// agendar/reagendar.
// =========================================================================
// Normaliza a hora vinda do banco pra sempre virar "HH:MM:SS" — se já
// vier com segundos (ex: "19:45:00", comum quando a coluna é do tipo
// TIME), evita duplicar e gerar uma data inválida tipo "19:45:00:00"
// (que o JS silenciosamente trata como Invalid Date, e a comparação
// "momento <= agora" nunca fica verdadeira — o aviso nunca dispara).
// CORRIGIDO: antes devolvia só "HH:MM:SS", e o new Date(...) que usava
// isso interpretava como horário LOCAL DO SERVIDOR (Render roda em
// UTC) — então "13:30" virava 13:30 UTC = 10:30 de Brasília, e todos os
// cálculos de "já passou da hora?" ficavam 3h errados. Agora fixa
// explicitamente o fuso -03:00 (Brasília), então o cálculo fica certo
// não importa em que fuso o servidor esteja rodando.
function normalizarHoraParaData(hora) {
    const partes = hora.toString().split(':');
    const h = (partes[0] || '00').padStart(2, '0');
    const m = (partes[1] || '00').padStart(2, '0');
    return `${h}:${m}:00-03:00`;
}

async function verificarHorarioColeta() {
    try {
        const agora = new Date();

        const cargas = await pool.query(`
            SELECT id, caminhao_designado_id, descricao, col_cidade, col_uf, data_coleta, hora_coleta
            FROM cargas
            WHERE caminhao_designado_id IS NOT NULL
              AND status = 'EM_ANDAMENTO'
              AND aviso_hora_coleta_enviado = FALSE
              AND data_coleta IS NOT NULL AND hora_coleta IS NOT NULL
        `);
        for (const c of cargas.rows) {
            const dataStr = c.data_coleta.toISOString ? c.data_coleta.toISOString().split('T')[0] : c.data_coleta;
            const momento = new Date(`${dataStr}T${normalizarHoraParaData(c.hora_coleta)}`);
            console.log(`[HORARIO COLETA] carga #${c.id} — momento calculado: ${momento} | agora: ${agora} | dispara: ${momento <= agora}`);
            if (momento <= agora) {
                await notificarCaminhaoDesignadoAgora(
                    c.caminhao_designado_id,
                    `Coletar carga programada #${c.id} — ${c.descricao || ''} (${c.col_cidade}/${c.col_uf})`,
                    'COLETAR_AGORA', c.id, 'mercado'
                );
                await pool.query('UPDATE cargas SET aviso_hora_coleta_enviado = TRUE WHERE id = $1', [c.id]);
            }
        }

        const coletas = await pool.query(`
            SELECT co.id, co.caminhao_id, co.tipo_carga, co.col_cidade, co.col_uf, co.data_coleta, co.hora_coleta,
                   co.destinatario_nome, co.ent_cidade, co.ent_uf, co.embarcador_id,
                   e.admin_email
            FROM coletas_frota co
            JOIN embarcadores e ON e.id = co.embarcador_id
            WHERE co.caminhao_id IS NOT NULL
              AND co.status = 'AGENDADA'
              AND co.aviso_hora_coleta_enviado = FALSE
              AND co.data_coleta IS NOT NULL AND co.hora_coleta IS NOT NULL
        `);
        for (const c of coletas.rows) {
            const dataStr = c.data_coleta.toISOString ? c.data_coleta.toISOString().split('T')[0] : c.data_coleta;
            const momento = new Date(`${dataStr}T${normalizarHoraParaData(c.hora_coleta)}`);
            console.log(`[HORARIO COLETA] coleta #${c.id} — momento calculado: ${momento} | agora: ${agora} | dispara: ${momento <= agora}`);
            if (momento <= agora) {
                await notificarCaminhaoDesignadoAgora(
                    c.caminhao_id,
                    `Coletar carga programada #${c.id} — ${c.tipo_carga || ''} (${c.col_cidade}/${c.col_uf})`,
                    'COLETAR_AGORA', c.id, 'coleta_propria'
                );

                // CORRIGIDO: não força mais o status pra EM_ANDAMENTO —
                // o sistema não sabe de verdade se o motorista coletou
                // ou não (pode ter tido pane, trânsito, esquecimento). A
                // coleta continua "AGENDADA", e a tela de Agendamentos
                // calcula sozinha se está atrasada (comparando a hora
                // marcada com agora) — vira um aviso visual pra
                // funcionária ligar pro motorista, não uma mentira do
                // sistema fingindo que já saiu. Só o próprio motorista,
                // tocando em "Coletar" no app, muda o status de verdade.
                await pool.query(
                    "UPDATE coletas_frota SET aviso_hora_coleta_enviado = TRUE WHERE id = $1",
                    [c.id]
                );

                // Se o destino ainda não foi informado, agora ele passa
                // a ser obrigatório de verdade — avisa por e-mail.
                const faltaDestino = !c.destinatario_nome || !c.ent_cidade || !c.ent_uf;
                if (faltaDestino) {
                    await avisarGestores(
                        c.embarcador_id,
                        `ATENÇÃO: chegou a hora da coleta #${c.id} (${c.tipo_carga || ''}, ${c.col_cidade}/${c.col_uf}) e o DESTINO ainda não foi informado.`,
                        'ALERTA', c.id, 'coleta_propria', 'Falta o destino da coleta'
                    );
                }
                if (faltaDestino && c.admin_email) {
                    try {
                        await enviarEmailAvisoOperacional(
                            c.admin_email,
                            `TACLOG — Falta o destino da coleta #${c.id}`,
                            `<p>Chegou a hora agendada da coleta <strong>#${c.id}</strong> (${c.tipo_carga || ''}, ${c.col_cidade}/${c.col_uf}), mas o <strong>destino ainda não foi informado</strong>.</p>
                             <p>Entra no TACLOG e completa o destino dessa coleta o quanto antes.</p>`
                        );
                    } catch (e) {
                        console.error(`[AVISO DESTINO FALTANDO] erro ao enviar e-mail da coleta #${c.id}:`, e.message);
                    }
                }
            }
        }

        // NOVO: avisa 1h antes da coleta agendada se ainda não tiver
        // caminhão atribuído — dá tempo da transportadora resolver
        // antes da hora chegar.
        const semCaminhao = await pool.query(`
            SELECT co.id, co.embarcador_id, co.tipo_carga, co.col_cidade, co.col_uf, co.data_coleta, co.hora_coleta,
                   e.admin_email
            FROM coletas_frota co
            JOIN embarcadores e ON e.id = co.embarcador_id
            WHERE co.caminhao_id IS NULL
              AND co.status = 'AGENDADA'
              AND co.aviso_caminhao_faltando_enviado = FALSE
              AND co.data_coleta IS NOT NULL AND co.hora_coleta IS NOT NULL
        `);
        for (const c of semCaminhao.rows) {
            const dataStr = c.data_coleta.toISOString ? c.data_coleta.toISOString().split('T')[0] : c.data_coleta;
            const momento = new Date(`${dataStr}T${normalizarHoraParaData(c.hora_coleta)}`);
            const minutosParaAColeta = (momento - agora) / 60000;
            // dispara na janela de 1h antes (e ainda não muito atrasado,
            // pra não mandar aviso de coisa que já devia ter acontecido)
            if (minutosParaAColeta <= 60 && minutosParaAColeta > -120) {
                // NOVO: as gestoras também são avisadas (uma vez só — o
                // flag abaixo é marcado sempre, tenha e-mail do admin ou não).
                await avisarGestores(
                    c.embarcador_id,
                    `ATENÇÃO: a coleta #${c.id} (${c.tipo_carga || ''}, ${c.col_cidade}/${c.col_uf}) é daqui a pouco e AINDA NÃO TEM CAMINHÃO atribuído.`,
                    'ALERTA', c.id, 'coleta_propria', 'Falta atribuir caminhão'
                );
                if (c.admin_email) {
                    try {
                        await enviarEmailAvisoOperacional(
                            c.admin_email,
                            `TACLOG — Falta atribuir caminhão pra coleta #${c.id}`,
                            `<p>A coleta <strong>#${c.id}</strong> (${c.tipo_carga || ''}, ${c.col_cidade}/${c.col_uf}) está agendada pra daqui a pouco e <strong>ainda não tem caminhão atribuído</strong>.</p>
                             <p>Entra no TACLOG e atribui um caminhão antes da hora da coleta.</p>`
                        );
                    } catch (e) {
                        console.error(`[AVISO CAMINHÃO FALTANDO] erro ao enviar e-mail da coleta #${c.id}:`, e.message);
                    }
                }
                await pool.query('UPDATE coletas_frota SET aviso_caminhao_faltando_enviado = TRUE WHERE id = $1', [c.id]);
            }
        }
    } catch (e) {
        console.error('[VERIFICAR HORÁRIO COLETA] erro:', e.message);
    }
}
setInterval(verificarHorarioColeta, 30000);

// Lista coletas com filtros opcionais — data (intervalo), status e
// caminhão — pra funcionária ver a agenda do dia/semana ou de um veículo
// específico, exatamente como ela faria numa planilha, só que automático.
app.get('/api/transportadora/coletas', authenticateToken, exigirTransportadora, async (req, res) => {
    const { data_inicio, data_fim, status, caminhao_id } = req.query;
    try {
        let sql = `
            SELECT co.*, cam.placa AS caminhao_placa, car.placa AS carreta_placa
            FROM coletas_frota co
            LEFT JOIN caminhoes cam ON cam.id = co.caminhao_id
            LEFT JOIN carretas car ON car.id = co.carreta_id
            WHERE co.embarcador_id = $1
        `;
        const params = [req.user.id];

        if (data_inicio) {
            params.push(data_inicio);
            sql += ` AND co.data_coleta >= $${params.length}`;
        }
        if (data_fim) {
            params.push(data_fim);
            sql += ` AND co.data_coleta <= $${params.length}`;
        }
        if (status) {
            params.push(status);
            sql += ` AND co.status = $${params.length}`;
        }
        if (caminhao_id) {
            params.push(caminhao_id);
            sql += ` AND co.caminhao_id = $${params.length}`;
        }
        sql += ` ORDER BY co.data_coleta ASC, co.hora_coleta ASC`;

        const result = await pool.query(sql, params);
        res.json(result.rows);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/transportadora/coletas/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT co.*, cam.placa AS caminhao_placa, car.placa AS carreta_placa
            FROM coletas_frota co
            LEFT JOIN caminhoes cam ON cam.id = co.caminhao_id
            LEFT JOIN carretas car ON car.id = co.carreta_id
            WHERE co.id = $1 AND co.embarcador_id = $2
        `, [req.params.id, req.user.id]);
        if (result.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada.' });
        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/transportadora/coletas', authenticateToken, exigirTransportadora, async (req, res) => {
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        // CORRIGIDO: destino (destinatario_nome/ent_cidade/ent_uf) e
        // caminhão deixaram de ser obrigatórios pra CRIAR a coleta — a
        // transportadora pode saber só "o quê, quando e de onde
        // coletar" e completar o resto depois, editando. O front já
        // tinha sido ajustado, mas essa trava aqui no backend tinha
        // ficado esquecida com a lista antiga.
        if (!c.data_coleta || !c.tipo_carga || !c.remetente_nome || !c.col_cidade || !c.col_uf) {
            return res.status(400).json({
                error: 'Campos obrigatórios: data_coleta, tipo_carga, remetente_nome, col_cidade, col_uf'
            });
        }

        const valorFrete = normalizarValorFrete(c.valor_frete);
        if (valorFrete === null || valorFrete <= 0) {
            return res.status(400).json({ error: 'Informe o valor do frete (maior que zero) para agendar a coleta.' });
        }
        c.valor_frete = valorFrete;

        const erroVeiculo = await validarVeiculoDaFrota(embarcador_id, c.caminhao_id, c.carreta_id);
        if (erroVeiculo) return res.status(400).json({ error: erroVeiculo });

        // Snapshot da placa do caminhão/carreta NO MOMENTO da coleta —
        // preenchido automaticamente aqui, nunca pelo que vier do front,
        // pra garantir que reflita o veículo real vinculado agora e
        // sobreviva a qualquer troca de placa/baixa no cadastro depois.
        let caminhaoPlacaSnapshot = null;
        let carretaPlacaSnapshot = null;
        if (c.caminhao_id) {
            const camRes = await pool.query('SELECT placa FROM caminhoes WHERE id = $1', [c.caminhao_id]);
            if (camRes.rows.length > 0) caminhaoPlacaSnapshot = camRes.rows[0].placa;
        }
        if (c.carreta_id) {
            const carRes = await pool.query('SELECT placa FROM carretas WHERE id = $1', [c.carreta_id]);
            if (carRes.rows.length > 0) carretaPlacaSnapshot = carRes.rows[0].placa;
        }

        const camposEnviados = CAMPOS_COLETA_PERMITIDOS.filter(campo => c[campo] !== undefined && c[campo] !== '');
        const colunas = ['embarcador_id', 'criado_por_id', 'criado_por_nome', 'caminhao_placa_snapshot', 'carreta_placa_snapshot', ...camposEnviados];
        const valores = [embarcador_id, embarcador_id, nomeDoAtor(req), caminhaoPlacaSnapshot, carretaPlacaSnapshot, ...camposEnviados.map(campo => c[campo])];
        const placeholders = valores.map((_, i) => `$${i + 1}`).join(', ');

        const sql = `INSERT INTO coletas_frota (${colunas.join(', ')}) VALUES (${placeholders}) RETURNING *`;
        const result = await pool.query(sql, valores);

        if (c.caminhao_id) {
            const dataFmt = c.data_coleta || '';
            const horaFmt = c.hora_coleta ? ` às ${c.hora_coleta}` : '';
            await notificarCaminhaoDesignadoAgora(
                c.caminhao_id,
                `Nova coleta agendada para ${dataFmt}${horaFmt} — ${c.remetente_nome} (${c.col_cidade}/${c.col_uf}).`
            );
        } else {
            const dataFmt = c.data_coleta || '';
            const horaFmt = c.hora_coleta ? ` às ${c.hora_coleta}` : '';
            await avisarGestores(
                embarcador_id,
                `Nova coleta agendada para ${dataFmt}${horaFmt} — ${c.remetente_nome || ''} (${c.col_cidade || ''}/${c.col_uf || ''}). Ainda SEM caminhão atribuído.`,
                'GERAL', result.rows[0].id, 'coleta_propria', 'Nova coleta agendada'
            );
        }

        res.status(201).json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/transportadora/coletas/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const c = req.body;
    const embarcador_id = req.user.id;
    try {
        const check = await pool.query('SELECT status, caminhao_id, data_coleta, hora_coleta FROM coletas_frota WHERE id = $1 AND embarcador_id = $2', [id, embarcador_id]);
        if (check.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada ou sem permissão.' });
        if (check.rows[0].status === 'CANCELADA') {
            return res.status(400).json({ error: 'Não é possível editar uma coleta cancelada.' });
        }
        const caminhaoAnteriorId = check.rows[0].caminhao_id;

        const erroVeiculo = await validarVeiculoDaFrota(embarcador_id, c.caminhao_id, c.carreta_id);
        if (erroVeiculo) return res.status(400).json({ error: erroVeiculo });

        // Se o valor do frete veio na edição, não pode ser zerado/negativo.
        if (c.valor_frete !== undefined) {
            const valorFrete = normalizarValorFrete(c.valor_frete);
            if (valorFrete === null || valorFrete <= 0) {
                return res.status(400).json({ error: 'O valor do frete deve ser maior que zero.' });
            }
            c.valor_frete = valorFrete;
        }

        const camposEnviados = CAMPOS_COLETA_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });

        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        const result = await pool.query(
            `UPDATE coletas_frota SET ${setClause}, editado_por_nome = $${camposEnviados.length + 1}, atualizado_em = now() WHERE id = $${camposEnviados.length + 2} AND embarcador_id = $${camposEnviados.length + 3} RETURNING *`,
            [...valores, nomeDoAtor(req), id, embarcador_id]
        );

        // CORRIGIDO: antes só reavisava se o CAMINHÃO mudasse — agora
        // também reavisa se a data ou a hora da coleta mudaram (mesmo
        // caminhão, mesmo motorista, mas ele precisa saber do novo
        // horário). O alvo do aviso é sempre o caminhão mais atual: o que
        // veio nesta edição, ou — se essa edição nem mexeu no caminhão
        // (ex: o "editar rapidinho data/hora") — o que já estava
        // designado antes.
        const caminhaoAlvo = c.caminhao_id !== undefined ? c.caminhao_id : caminhaoAnteriorId;
        const caminhaoMudou = c.caminhao_id !== undefined && c.caminhao_id != caminhaoAnteriorId;
        const dataMudou = c.data_coleta !== undefined && c.data_coleta !== check.rows[0].data_coleta;
        const horaMudou = c.hora_coleta !== undefined && c.hora_coleta !== check.rows[0].hora_coleta;

        if (caminhaoAlvo && (caminhaoMudou || dataMudou || horaMudou)) {
            const dataFmt = result.rows[0].data_coleta || '';
            const horaFmt = result.rows[0].hora_coleta ? ` às ${result.rows[0].hora_coleta}` : '';
            await notificarCaminhaoDesignadoAgora(
                caminhaoAlvo,
                `Coleta atualizada — agora em ${dataFmt}${horaFmt} — ${result.rows[0].remetente_nome} (${result.rows[0].col_cidade}/${result.rows[0].col_uf}).`
            );
        }

        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// Rota dedicada só pra mudança de status — mantém a esteira operacional
// (AGENDADA → EM_COLETA → COLETADA → EM_TRANSITO → ENTREGUE, ou
// CANCELADA a qualquer momento) separada da edição normal dos dados.
app.put('/api/transportadora/coletas/:id/status', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const { status } = req.body;
    const embarcador_id = req.user.id;
    try {
        if (!STATUS_COLETA_VALIDOS.includes(status)) {
            return res.status(400).json({ error: `Status inválido. Use um de: ${STATUS_COLETA_VALIDOS.join(', ')}` });
        }
        const result = await pool.query(
            'UPDATE coletas_frota SET status = $1, editado_por_nome = $2, atualizado_em = now() WHERE id = $3 AND embarcador_id = $4 RETURNING *',
            [status, nomeDoAtor(req), id, embarcador_id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada ou sem permissão.' });
        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.delete('/api/transportadora/coletas/:id', authenticateToken, exigirTransportadora, async (req, res) => {
    const { id } = req.params;
    const embarcador_id = req.user.id;
    try {
        // NOVO: mesma regra da carga do Mercado — coleta já ENTREGUE
        // (finalizada) só um administrador pode cancelar.
        const check = await pool.query('SELECT status FROM coletas_frota WHERE id = $1 AND embarcador_id = $2', [id, embarcador_id]);
        if (check.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada ou sem permissão.' });
        if (check.rows[0].status === 'ENTREGUE' && !ehAdminEmbarcador(req.user)) {
            return res.status(403).json({ error: 'Apenas administradores podem cancelar uma coleta já finalizada (entregue).' });
        }

        const result = await pool.query(
            "UPDATE coletas_frota SET status = 'CANCELADA', editado_por_nome = $1, atualizado_em = now() WHERE id = $2 AND embarcador_id = $3 RETURNING id",
            [nomeDoAtor(req), id, embarcador_id]
        );
        if (result.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada ou sem permissão.' });
        res.json({ message: 'Coleta cancelada com sucesso!' });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// NOTIFICAÇÕES DO MOTORISTA — espelha as notificações do embarcador,
// alimentada pelo scheduler verificarAvisosColeta() abaixo. O app mobile
// consulta isso periodicamente (mesmo padrão de polling já usado nas
// ofertas de carga).
// =========================================================================
app.get('/api/motorista/notificacoes', authenticateToken, async (req, res) => {
    if (req.user.role !== 'motorista') return res.status(403).json({ error: 'Apenas motoristas possuem este tipo de notificação.' });
    try {
        const result = await pool.query(
            'SELECT * FROM notificacoes_motorista WHERE motorista_id = $1 ORDER BY data_criacao DESC LIMIT 50',
            [req.user.id]
        );
        res.json(result.rows);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/api/motorista/notificacoes/contagem', authenticateToken, async (req, res) => {
    if (req.user.role !== 'motorista') return res.status(403).json({ error: 'Apenas motoristas possuem este tipo de notificação.' });
    try {
        const result = await pool.query(
            'SELECT COUNT(*) FROM notificacoes_motorista WHERE motorista_id = $1 AND lida = false',
            [req.user.id]
        );
        res.json({ total_nao_lidas: parseInt(result.rows[0].count) });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/motorista/notificacoes/:id/marcar-lida', authenticateToken, async (req, res) => {
    const { id } = req.params;
    try {
        const check = await pool.query('SELECT id FROM notificacoes_motorista WHERE id = $1 AND motorista_id = $2', [id, req.user.id]);
        if (check.rows.length === 0) return res.status(403).json({ error: 'Notificação não encontrada ou sem permissão.' });
        await pool.query('UPDATE notificacoes_motorista SET lida = true WHERE id = $1', [id]);
        res.json({ message: 'Notificação marcada como lida.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/motorista/notificacoes/marcar-todas-lidas', authenticateToken, async (req, res) => {
    try {
        await pool.query('UPDATE notificacoes_motorista SET lida = true WHERE motorista_id = $1 AND lida = false', [req.user.id]);
        res.json({ message: 'Todas as notificações foram marcadas como lidas.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// RASTREAMENTO DA COLETA — devolve a última posição conhecida do
// motorista vinculado ao caminhão designado para a coleta. Reaproveita
// a tabela localizacao_atual, que já é alimentada pelo app do motorista
// em /api/motorista/localizacao (mesma que já move os pontos no mapa de
// "Motoristas Online e Livres"). Funciona mesmo se o painel foi fechado
// e reaberto, porque a posição vive no banco, não na sessão do usuário.
// =========================================================================
app.get('/api/transportadora/coletas/:id/localizacao', authenticateToken, exigirTransportadora, async (req, res) => {
    try {
        const coleta = await pool.query(
            'SELECT caminhao_id, status FROM coletas_frota WHERE id = $1 AND embarcador_id = $2',
            [req.params.id, req.user.id]
        );
        if (coleta.rows.length === 0) return res.status(404).json({ error: 'Coleta não encontrada.' });
        if (!coleta.rows[0].caminhao_id) return res.status(400).json({ error: 'Esta coleta não tem caminhão atribuído.' });

        const result = await pool.query(`
            SELECT
                m.id AS motorista_id, m.nome AS motorista_nome,
                ST_Y(l.ponto::geometry) AS lat, ST_X(l.ponto::geometry) AS lng,
                l.timestamp_atualizacao
            FROM caminhoes c
            JOIN motoristas m ON m.id = c.motorista_atual_id
            JOIN localizacao_atual l ON l.motorista_id = m.id
            WHERE c.id = $1
        `, [coleta.rows[0].caminhao_id]);

        if (result.rows.length === 0) {
            return res.status(404).json({ error: 'Nenhuma localização disponível para este caminhão no momento.' });
        }
        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// SCHEDULER: AVISOS DE COLETA
// Roda a cada 30 segundos. Para cada coleta AGENDADA (ou EM_COLETA) com
// tempo_antecedencia_aviso_minutos > 0, calcula o horário de disparo
// (data_coleta + hora_coleta − antecedência) e, ao chegar nesse horário,
// dispara os dois avisos combinados: um para o painel da transportadora
// (sino já existente) e outro para o motorista designado (sino novo no
// app, consultado por polling — fase "simples" combinada com o Marcelo;
// push de verdade via Firebase fica para uma fase futura).
// =========================================================================
async function verificarAvisosColeta() {
    try {
        const coletas = await pool.query(`
            SELECT co.*, cam.motorista_atual_id, cam.placa AS caminhao_placa, mot.nome AS motorista_nome
            FROM coletas_frota co
            LEFT JOIN caminhoes cam ON cam.id = co.caminhao_id
            LEFT JOIN motoristas mot ON mot.id = cam.motorista_atual_id
            WHERE co.status IN ('AGENDADA', 'EM_COLETA')
              AND co.tempo_antecedencia_aviso_minutos > 0
              AND (co.aviso_painel_enviado = false OR co.aviso_motorista_enviado = false)
              AND co.data_coleta IS NOT NULL
        `);

        for (const co of coletas.rows) {
            if (!co.hora_coleta) continue; // sem hora definida, não dá pra calcular antecedência

            const momentoColeta = new Date(`${co.data_coleta.toISOString().substring(0, 10)}T${co.hora_coleta}`);
            const momentoDisparo = new Date(momentoColeta.getTime() - co.tempo_antecedencia_aviso_minutos * 60000);

            if (momentoDisparo > new Date()) continue; // ainda não chegou a hora

            const mensagem = `Coleta #${co.id} agendada para ${co.data_coleta.toISOString().substring(0, 10)} às ${co.hora_coleta} — ${co.remetente_nome} (${co.col_cidade}/${co.col_uf}).`;

            if (!co.aviso_painel_enviado) {
                await pool.query(
                    'INSERT INTO notificacoes_embarcador (embarcador_id, mensagem) VALUES ($1, $2)',
                    [co.embarcador_id, mensagem]
                );
                // NOVO: mesma antecedência, agora também pras gestoras.
                const quemVai = co.motorista_nome ? `Motorista: ${co.motorista_nome}` : 'Ainda sem motorista/caminhão';
                const placaTxt = co.caminhao_placa ? ` — Placa: ${co.caminhao_placa}` : '';
                await avisarGestores(
                    co.embarcador_id,
                    `Aviso de coleta: ${mensagem} (${quemVai}${placaTxt})`,
                    'AVISO_ANTECEDENCIA', co.id, 'coleta_propria', 'Aviso de coleta próxima'
                );
            }

            if (!co.aviso_motorista_enviado && co.motorista_atual_id) {
                await pool.query(
                    'INSERT INTO notificacoes_motorista (motorista_id, coleta_id, mensagem) VALUES ($1, $2, $3)',
                    [co.motorista_atual_id, co.id, mensagem]
                );
            }

            await pool.query(
                'UPDATE coletas_frota SET aviso_painel_enviado = true, aviso_motorista_enviado = true WHERE id = $1',
                [co.id]
            );
            console.log(`[AVISO COLETA] Coleta #${co.id}: aviso disparado (painel${co.motorista_atual_id ? ' + motorista' : ' — sem motorista no caminhão'}).`);
        }
    } catch (e) {
        console.error('[AVISO COLETA] Erro ao verificar avisos de coleta:', e.message);
    }
}
setInterval(verificarAvisosColeta, 30000);

// =========================================================================
// PERFIL DO EMBARCADOR — consultar e editar os dados do próprio cadastro.
// CNPJ NUNCA é editável aqui: um CNPJ diferente é uma empresa diferente,
// com histórico próprio de cargas/documentos — trocar de CNPJ é um novo
// cadastro, não uma edição. Vale tanto para embarcador comum quanto
// transportadora — os campos são os mesmos, a única diferença entre os
// dois perfis é a flag is_transportadora (que também não é editável
// pelo próprio usuário, é definida pela plataforma).
// =========================================================================
const CAMPOS_PERFIL_EMBARCADOR_PERMITIDOS = [
    'razao_social', 'nome_fantasia', 'atividade_principal', 'inscricao_estadual',
    'telefone_empresa', 'email_empresa', 'site', 'rntrc_transportadora',
    'cep', 'logradouro', 'numero', 'complemento', 'bairro', 'cidade', 'uf',
    'admin_nome', 'admin_cargo', 'admin_fone', 'admin_email',
    'pub_responsavel', 'pub_fone', 'pub_celular', 'pub_email',
    'fin_responsavel', 'fin_cargo', 'fin_fone', 'fin_celular', 'fin_email',
    'exp_responsavel', 'exp_cargo', 'exp_fone', 'exp_email',
    'sac_responsavel', 'sac_cargo', 'sac_fone', 'sac_email',
    'meio_pagamento_pref', 'verificar_motoristas'
];

app.get('/api/embarcador/perfil', authenticateToken, async (req, res) => {
    if (req.user.role !== 'embarcador') return res.status(403).json({ error: 'Rota exclusiva de embarcadores.' });
    try {
        const result = await pool.query('SELECT * FROM embarcadores WHERE id = $1', [req.user.id]);
        if (result.rows.length === 0) return res.status(404).json({ error: 'Cadastro não encontrado.' });
        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

app.put('/api/embarcador/perfil', authenticateToken, async (req, res) => {
    if (req.user.role !== 'embarcador') return res.status(403).json({ error: 'Rota exclusiva de embarcadores.' });
    const c = req.body;
    try {
        // Trava explícita: mesmo que venha no corpo da requisição por engano
        // (ex: reenvio do formulário inteiro), cpf_cnpj nunca é alterado aqui.
        if (c.cpf_cnpj !== undefined) {
            return res.status(400).json({ error: 'O CNPJ não pode ser alterado. Um CNPJ diferente exige um novo cadastro.' });
        }

        const camposEnviados = CAMPOS_PERFIL_EMBARCADOR_PERMITIDOS.filter(campo => c[campo] !== undefined);
        if (camposEnviados.length === 0) return res.status(400).json({ error: 'Nenhum campo válido para atualizar.' });

        const setClause = camposEnviados.map((campo, i) => `${campo} = $${i + 1}`).join(', ');
        const valores = camposEnviados.map(campo => c[campo]);

        const result = await pool.query(
            `UPDATE embarcadores SET ${setClause} WHERE id = $${camposEnviados.length + 1} RETURNING *`,
            [...valores, req.user.id]
        );
        res.json(result.rows[0]);
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// Upload do logo da empresa — mesmo mecanismo (multer) já usado na foto
// de perfil do motorista e na foto de documento do caminhão.
app.post('/api/embarcador/logo', authenticateToken, upload.single('logo'), async (req, res) => {
    if (req.user.role !== 'embarcador') return res.status(403).json({ error: 'Rota exclusiva de embarcadores.' });
    try {
        if (!req.file) return res.status(400).json({ error: 'Nenhuma imagem enviada.' });
        const logoUrl = await uploadParaCloudinary(req.file.buffer, 'taclog/logo_empresa', 'image');
        await pool.query('UPDATE embarcadores SET logo_url = $1 WHERE id = $2', [logoUrl, req.user.id]);
        res.json({ message: 'Logo atualizado com sucesso!', logo_url: logoUrl });
    } catch (e) {
        console.error(e);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// NOVO: TERMOS DE USO E POLÍTICA DE PRIVACIDADE — ACEITE (LGPD)
//
// O texto vem de termos_taclog.js (mesmo texto que está nas páginas públicas
// do site). Cada pessoa aceita uma vez por VERSÃO do texto; quando a versão
// muda, o app/painel pedem o aceite de novo. O aceite fica guardado em
// aceites_termos (data, hora, versão, IP, aparelho) como prova.
// =========================================================================
function perfilDeAceite(user) {
    if (!user) return null;
    if (user.role === 'motorista') return { tipo: 'MOTORISTA', id: user.id };
    if (user.role === 'embarcador' && user.funcionario_id) return { tipo: 'FUNCIONARIO_EMBARCADOR', id: user.funcionario_id };
    if (user.role === 'embarcador') return { tipo: 'EMBARCADOR', id: user.id };
    return null;
}

// Público (sem login): o app e as páginas leem o texto daqui.
app.get('/api/termos', (req, res) => {
    res.set('Cache-Control', 'public, max-age=300');
    res.json({ versao: TERMOS.versao, atualizado_em: TERMOS.atualizado_em, secoes: TERMOS.secoes });
});

// A pessoa logada já aceitou a versão vigente?
app.get('/api/termos/status', authenticateToken, async (req, res) => {
    const perfil = perfilDeAceite(req.user);
    if (!perfil) return res.json({ precisa_aceitar: false, versao: TERMOS.versao });
    try {
        const r = await pool.query(
            'SELECT 1 FROM aceites_termos WHERE tipo_usuario = $1 AND usuario_id = $2 AND versao = $3 AND aceitou_termos = TRUE LIMIT 1',
            [perfil.tipo, perfil.id, TERMOS.versao]
        );
        res.json({
            precisa_aceitar: r.rows.length === 0,
            versao: TERMOS.versao,
            atualizado_em: TERMOS.atualizado_em,
            perfil: perfil.tipo,
            exige_localizacao: perfil.tipo === 'MOTORISTA',
            exige_poderes: perfil.tipo === 'EMBARCADOR',
        });
    } catch (e) {
        console.error('[TERMOS] status:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// Registra o aceite.
app.post('/api/termos/aceitar', authenticateToken, async (req, res) => {
    const perfil = perfilDeAceite(req.user);
    if (!perfil) return res.status(403).json({ error: 'Perfil sem aceite de termos.' });
    const b = req.body || {};
    if (b.versao !== TERMOS.versao) {
        return res.status(409).json({ error: 'VERSAO_DESATUALIZADA', message: 'Os termos foram atualizados. Leia a versão mais recente.', versao_vigente: TERMOS.versao });
    }
    if (b.aceitou_termos !== true) {
        return res.status(400).json({ error: 'É preciso aceitar os Termos de Uso e a Política de Privacidade para continuar.' });
    }
    if (perfil.tipo === 'MOTORISTA' && b.aceitou_localizacao !== true) {
        return res.status(400).json({ error: 'Para usar o aplicativo como motorista é preciso autorizar o uso da localização.' });
    }
    if (perfil.tipo === 'EMBARCADOR' && b.declarou_poderes !== true) {
        return res.status(400).json({ error: 'É preciso confirmar a declaração de poderes e de responsabilidade pelos dados cadastrados.' });
    }
    const origem = String(b.origem || '').toUpperCase() === 'WEB' ? 'WEB' : 'APP';
    const ip = (String(req.headers['x-forwarded-for'] || '').split(',')[0].trim()) || (req.socket && req.socket.remoteAddress) || null;
    const ua = String(req.headers['user-agent'] || '').slice(0, 400) || null;
    try {
        await pool.query(
            `INSERT INTO aceites_termos
                (tipo_usuario, usuario_id, versao, aceitou_termos, aceitou_localizacao, aceitou_comunicacoes, declarou_poderes, origem, ip, user_agent, empresa_id)
             VALUES ($1, $2, $3, TRUE, $4, $5, $6, $7, $8, $9, $10)`,
            [
                perfil.tipo, perfil.id, TERMOS.versao,
                b.aceitou_localizacao === true, b.aceitou_comunicacoes === true, b.declarou_poderes === true,
                origem, ip, ua,
                req.user.role === 'embarcador' ? req.user.id : null,
            ]
        );
        res.json({ message: 'Aceite registrado.', versao: TERMOS.versao });
    } catch (e) {
        console.error('[TERMOS] aceitar:', e.message);
        res.status(500).json({ error: e.message });
    }
});

// =========================================================================
// NOVO: NOTIFICAÇÕES PUSH (aparelho do motorista e da gestora)
//
// O app registra o "endereço" do celular (token do Firebase) logo após o
// login. A cada 15 segundos o servidor olha os avisos novos gravados em
// notificacoes_motorista / notificacoes_gestor e manda um push para os
// aparelhos da pessoa — funciona com a tela bloqueada e o app fechado.
// =========================================================================
function perfilDePush(user) {
    if (!user) return null;
    if (user.role === 'motorista') return { tipo: 'MOTORISTA', id: user.id };
    if (user.role === 'embarcador' && user.funcionario_id) return { tipo: 'GESTOR', id: user.funcionario_id };
    return null;
}

app.post('/api/push/registrar', authenticateToken, async (req, res) => {
    const perfil = perfilDePush(req.user);
    if (!perfil) return res.json({ message: 'Este perfil não recebe notificações no aparelho.', registrado: false });
    const token = String((req.body || {}).token || '').trim();
    if (token.length < 20) return res.status(400).json({ error: 'Token do aparelho inválido.' });
    try {
        await push.registrarAparelho(perfil.tipo, perfil.id, token, String((req.body || {}).plataforma || '').slice(0, 20));
        res.json({ message: 'Aparelho registrado.', registrado: true });
    } catch (e) {
        console.error('[PUSH] registrar:', e.message);
        res.status(500).json({ error: e.message });
    }
});

app.post('/api/push/remover', authenticateToken, async (req, res) => {
    const token = String((req.body || {}).token || '').trim();
    if (!token) return res.json({ message: 'Nada a remover.' });
    try {
        await push.removerAparelho(token);
        res.json({ message: 'Aparelho removido.' });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Botão "testar notificação": manda um push de teste para os aparelhos de
// quem está logado e diz o que aconteceu.
app.post('/api/push/teste', authenticateToken, async (req, res) => {
    const perfil = perfilDePush(req.user);
    if (!perfil) return res.status(403).json({ error: 'Este perfil não recebe notificações no aparelho.' });
    if (!push.configurado()) {
        return res.json({ configurado: false, enviados: 0, message: 'O servidor ainda não está configurado para enviar notificações (falta a chave do Firebase).' });
    }
    try {
        const r = await push.enviarParaUsuario(perfil.tipo, perfil.id, 'TACLOG — teste', 'Se você está vendo este aviso, as notificações estão funcionando.', { tipo: 'TESTE' });
        let message = 'Notificação de teste enviada.';
        if (r.semAparelho) message = 'Nenhum aparelho registrado para esta conta. Abra o aplicativo, aceite as notificações e tente de novo.';
        else if (r.enviados === 0) message = 'Não foi possível entregar: ' + (r.ultimoErro || 'erro desconhecido');
        res.json({ configurado: true, enviados: r.enviados, falhas: r.falhas, message });
    } catch (e) {
        console.error('[PUSH] teste:', e.message);
        res.status(500).json({ error: e.message });
    }
});

setInterval(() => { push.enviarPendentes(); }, 15000);

app.listen(port, () => {
    console.log(`TACLOG V7 (Cadastro V2 - Caminhões/Carretas) rodando na porta ${port}`);
});


