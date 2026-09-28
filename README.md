# Omarchy OpenVPN Manager

Gerenciador nativo de conexões OpenVPN para o Linux Omarchy.

## Recursos

- **Ícone na Barra de Tarefas**:
  - Exibe o status da conexão diretamente na barra do Omarchy.
  - Ícone dinâmico: opaco quando desconectado, pulsante ao conectar, iluminado na cor do tema com ponto de status quando conectado.
  - Tooltip informativo com nome da VPN e endereço IP ativo.
- **Painel Pop-up Integrado (Quickshell)**:
  - Hero header com botão liga/desliga rápido (`ToggleSwitch`).
  - Lista de todas as conexões OpenVPN cadastradas.
  - Detalhes de cada perfil (servidor, usuário, status, IP).
  - Editor de credenciais inline (usuário e senha) salvo com segurança no NetworkManager.
  - Botão de importação direta de arquivos `.ovpn` via seletor de arquivos.
  - Visualizador de logs do OpenVPN/NetworkManager em tempo real.
- **Atalhos Rápidos no Ícone da Barra**:
  - **Clique Esquerdo**: Abre/fecha o painel pop-up.
  - **Clique Direito**: Conecta ou desconecta rapidamente a conexão ativa ou principal.
  - **Clique do Meio**: Atualiza o status e IPs.
- **Integração com Omarchy**:
  - Notificações de desktop nativas (`omarchy-notification-send`).
  - Suporte ao IPC (`omarchy-shell openvpn toggle`).
  - Atalho no menu de aplicativos do Omarchy (`Super` -> OpenVPN Manager).
  - Utilitário de linha de comando: `omarchy-openvpn`.
