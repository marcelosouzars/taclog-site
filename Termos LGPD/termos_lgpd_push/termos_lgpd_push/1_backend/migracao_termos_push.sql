-- =========================================================================
-- TACLOG - ACEITE DOS TERMOS (LGPD) + NOTIFICAÇÕES PUSH
--
-- 1) aceites_termos: guarda cada aceite dos Termos de Uso / Política de
--    Privacidade (quem, qual versão, quando, de onde) — é a prova do aceite.
-- 2) dispositivos_push: o "endereço" do celular de cada motorista/gestora,
--    usado para mandar notificação com o app fechado.
-- 3) push_enviado_em: marca quais avisos já viraram notificação no celular.
--
-- Pode rodar mais de uma vez sem problema. Rodar no editor SQL do Neon
-- ANTES de publicar o novo server.js.
-- =========================================================================

-- 1) ACEITES -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aceites_termos (
    id SERIAL PRIMARY KEY,
    tipo_usuario VARCHAR(30) NOT NULL,          -- MOTORISTA | EMBARCADOR | FUNCIONARIO_EMBARCADOR
    usuario_id INTEGER NOT NULL,                -- id na tabela do tipo acima
    empresa_id INTEGER,                         -- embarcador (empresa) quando aplicável
    versao VARCHAR(20) NOT NULL,                -- versão do texto aceito (ex.: 1.0)
    aceitou_termos BOOLEAN NOT NULL DEFAULT TRUE,
    aceitou_localizacao BOOLEAN NOT NULL DEFAULT FALSE,
    aceitou_comunicacoes BOOLEAN NOT NULL DEFAULT FALSE,
    declarou_poderes BOOLEAN NOT NULL DEFAULT FALSE,
    origem VARCHAR(10),                         -- APP | WEB
    ip VARCHAR(64),
    user_agent TEXT,
    aceito_em TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_aceites_termos_usuario
    ON aceites_termos (tipo_usuario, usuario_id, versao);

-- 2) APARELHOS PARA PUSH -----------------------------------------------------
CREATE TABLE IF NOT EXISTS dispositivos_push (
    id SERIAL PRIMARY KEY,
    tipo_usuario VARCHAR(20) NOT NULL,          -- MOTORISTA | GESTOR
    usuario_id INTEGER NOT NULL,                -- motoristas.id ou funcionarios_embarcador.id
    token TEXT NOT NULL UNIQUE,                 -- token do Firebase do aparelho
    plataforma VARCHAR(20),                     -- android | web
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em TIMESTAMP NOT NULL DEFAULT NOW(),
    atualizado_em TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dispositivos_push_usuario
    ON dispositivos_push (tipo_usuario, usuario_id) WHERE ativo = TRUE;

-- 3) MARCA DE "JÁ VIROU PUSH" NOS AVISOS -------------------------------------
ALTER TABLE notificacoes_motorista ADD COLUMN IF NOT EXISTS push_enviado_em TIMESTAMP;
ALTER TABLE notificacoes_gestor    ADD COLUMN IF NOT EXISTS push_enviado_em TIMESTAMP;

-- Os avisos que já existem NÃO devem virar push agora (evita uma enxurrada
-- de notificações antigas no primeiro minuto).
UPDATE notificacoes_motorista SET push_enviado_em = NOW() WHERE push_enviado_em IS NULL;
UPDATE notificacoes_gestor    SET push_enviado_em = NOW() WHERE push_enviado_em IS NULL;

CREATE INDEX IF NOT EXISTS idx_notif_motorista_push_pendente
    ON notificacoes_motorista (id) WHERE push_enviado_em IS NULL;
CREATE INDEX IF NOT EXISTS idx_notif_gestor_push_pendente
    ON notificacoes_gestor (id) WHERE push_enviado_em IS NULL;

-- Conferência: devem aparecer as 2 tabelas e as 2 colunas.
SELECT table_name FROM information_schema.tables
WHERE table_name IN ('aceites_termos', 'dispositivos_push')
ORDER BY table_name;

SELECT table_name, column_name FROM information_schema.columns
WHERE column_name = 'push_enviado_em'
  AND table_name IN ('notificacoes_motorista', 'notificacoes_gestor')
ORDER BY table_name;
