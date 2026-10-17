# TACLOG — Termos de Uso, LGPD e Notificações (pacote v1)

Tudo que está nesta pasta são arquivos COMPLETOS: é só copiar por cima dos que já existem.

## PARTE A — Termos e Privacidade (já funciona; falta só os dados da empresa)

### Ordem para publicar (importante)

1. **Neon (banco):** abra o editor SQL e rode o arquivo `1_backend/migracao_termos_push.sql`. Pode rodar mais de uma vez sem problema. No final aparecem as 2 tabelas e as 2 colunas novas.
2. **Backend (GitHub → Render):** copie para a pasta do `taclog-backend`, por cima: `server.js`, `termos_taclog.js` e `push_fcm.js` (os dois últimos são novos, ficam ao lado do server.js). O server.js novo já inclui tudo o que foi feito antes (fotos dos veículos, avisos das gestoras, etc.).
3. **Web:** copie a pasta `3_web/lib` por cima do `lib` do projeto web e publique como de costume.
4. **App:** copie `2_app/lib` por cima do `lib` do app. (O `main.dart` mudou: ele agora prepara o Firebase.) As notificações exigem a Parte B antes de gerar o APK.
5. **Site público:** coloque `4_site/termos.html` e `4_site/privacidade.html` na raiz do repositório do site (o mesmo onde está o `index.html`). Eles ficam em `www.taclog.com.br/termos.html` e `www.taclog.com.br/privacidade.html`. **Esse segundo endereço é o que o Google Play pede como "URL da Política de Privacidade".**

### O que a pessoa vê

- **App e web:** depois do login aparece "Antes de começar", com o resumo do essencial, o botão "Ler o texto completo" e as caixas "Li e concordo". Motorista marca também a autorização de localização; titular da empresa marca a declaração de poderes; a caixa de anúncios de parceiros é opcional. Sem aceitar, não entra. Aparece só uma vez (e de novo se o texto ganhar versão nova).
- Quem já estava logado antes também passa pela tela na próxima abertura.
- Menu "Termos e Privacidade" fica disponível a qualquer momento no app e no portal.
- O servidor guarda cada aceite: quem, versão, data/hora, IP, aparelho e se foi app ou web (é a prova em caso de disputa).

### O que ainda preciso de você (os textos estão com "[PREENCHER ...]")

Razão social, CNPJ, endereço da Vetix, nome do encarregado de dados (DPO — pode ser você), e-mail de privacidade (ex.: privacidade@taclog.com.br), telefone/WhatsApp, canal de suporte e o valor máximo de responsabilidade (cláusula 8). Também confirme os prazos que usei: 10 dias para resposta a incidentes, guarda por 12 meses e 15 dias para atender pedidos de titulares. Com isso eu regenero tudo (backend, app, web e site) de uma vez.

## PARTE B — Notificações com tela bloqueada / app fechado

Como funciona: qualquer aviso que o sistema cria para o motorista ou para a gestora (nova coleta, hora da coleta, etc.) vira notificação no celular em até 15 segundos, mesmo com o app fechado. O aparelho se cadastra sozinho quando a pessoa entra no app e se descadastra quando ela sai (celular de quem saiu não recebe mais avisos da conta).

### Passo 1 — Criar o projeto no Firebase (grátis)

1. Entre em https://console.firebase.google.com com a conta Google da Vetix e clique em **Adicionar projeto**. Nome: `TACLOG`. Pode desligar o Google Analytics.
2. Dentro do projeto, clique no ícone do **Android** para adicionar um app. Em "Nome do pacote" informe o **applicationId** do app (aparece em `android/app/build.gradle`; se não souber, me mande esse arquivo). Apelido: `TACLOG Motorista`. Clique em registrar.
3. Baixe o arquivo **google-services.json** e me envie aqui na conversa (ele não é secreto; só identifica o app). Pode pular os demais passos que o Firebase mostra — eu ajusto os arquivos.

### Passo 2 — Chave para o servidor enviar (esta SIM é secreta)

1. No Firebase: engrenagem ⚙ ao lado de "Visão geral" → **Configurações do projeto** → aba **Contas de serviço** → **Gerar nova chave privada**. Baixa um arquivo `.json`.
2. No **Render** → serviço `taclog-backend` → **Environment** → **Add Environment Variable**: nome `FIREBASE_SERVICE_ACCOUNT`, valor = o conteúdo INTEIRO do arquivo (abra no Bloco de Notas, copie tudo, cole). Salve; o Render reinicia sozinho.
3. **Nunca** coloque esse arquivo no GitHub nem me envie na conversa. Nos logs do Render deve aparecer: `[PUSH] Firebase configurado (projeto ...)`.

### Passo 3 — Arquivos do Android para eu ajustar

Me envie (anexando aqui): `pubspec.yaml`, `android/settings.gradle` (ou `.kts`), `android/build.gradle` (ou `.kts`), `android/app/build.gradle` (ou `.kts`), `android/app/src/main/AndroidManifest.xml` e o `google-services.json`. Eu devolvo os arquivos completos, prontos para colar, com as bibliotecas do Firebase, a permissão de notificação do Android 13+ e o ícone/canal configurados. Depois é só gerar o APK novo.

### Passo 4 — Testar

Abra o app novo, entre, aceite as notificações quando o Android perguntar e toque no **sininho com ondas** no topo (Testar notificação). Feche o app, bloqueie a tela e toque de novo de outro aparelho/pelo portal para ver chegar. Se a mensagem disser "falta a chave do Firebase", o Passo 2 não foi concluído.

### Limites desta primeira versão

- **Android:** completo. **iPhone (PWA):** o iOS só aceita notificação de PWA com o app instalado na tela inicial (iOS 16.4+) e exige outra configuração (web push); fica para a próxima etapa.
- Avisos para o motorista TAC autônomo sobre **ofertas do marketplace** (matchmaking) ainda não geram aviso próprio; hoje o push cobre tudo que passa pela tabela de avisos do motorista e da gestora (coletas da transportadora, agendamentos, etc.). Podemos ligar as ofertas em seguida.
- Alguns celulares (Xiaomi, Samsung, Huawei) economizam bateria matando apps; se uma notificação não chegar com o app fechado, orientar o motorista a permitir "sem restrições de bateria" para o TACLOG.

## Pendências de segurança (antes de abrir para clientes reais)

- Reativar a criptografia (hash) das senhas, hoje guardadas em texto puro. A política só promete proteção das credenciais depois disso.
- Tirar a URL do banco que está escrita dentro do server.js (usar somente a variável de ambiente do Render).
