import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "andreprohmann.openvpn"
  ipcTarget: "openvpn"
  manageIpc: true

  // State properties
  property var vpns: []
  property bool connected: false
  property bool connecting: false
  property string activeName: ""
  property string activeUuid: ""
  property string activeIp: ""
  property string activeDevice: ""
  property string activeServer: ""
  property bool busy: false
  property string lastError: ""

  // Inline credential editor state
  property string editingUuid: ""
  property string editingName: ""
  property string editingUsername: ""
  property string editingPassword: ""
  property bool connectAfterSave: false

  // Logs drawer state
  property bool showLogs: false
  property var logLines: []

  // Styling helpers
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Status text for tooltips and badges
  readonly property string statusSummary: {
    if (connected) return "Conectado a " + (activeName || "OpenVPN") + (activeIp ? " (" + activeIp + ")" : "")
    if (connecting) return "Conectando ao OpenVPN..."
    return "OpenVPN Desconectado"
  }

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/andreprohmann.openvpn/openvpn_backend.py"

  // -------------------------------------------------------------------------
  // Logic & Actions
  // -------------------------------------------------------------------------

  function refresh() {
    if (!statusProc.running) {
      statusProc.running = true
    }
  }

  function connectVpn(target) {
    if (!target || busy) return
    busy = true
    connecting = true
    lastError = ""
    actionProc.command = ["python3", root.scriptPath, "connect", target]
    actionProc.running = true
  }

  function disconnectVpn(target) {
    if (busy) return
    busy = true
    lastError = ""
    var args = ["python3", root.scriptPath, "disconnect"]
    if (target) args.push(target)
    actionProc.command = args
    actionProc.running = true
  }

  function toggleDefault() {
    if (connected) {
      disconnectVpn(activeUuid)
    } else if (vpns.length > 0) {
      var target = vpns[0]
      if (target.has_saved_password) {
        connectVpn(target.uuid)
      } else {
        openCredentialsEditor(target, true)
      }
    } else {
      importOvpn()
    }
  }

  function importOvpn() {
    if (importProc.running) return
    lastError = ""
    importProc.running = true
  }

  function openCredentialsEditor(vpn, andConnect) {
    editingUuid = vpn.uuid
    editingName = vpn.name
    editingUsername = vpn.username || ""
    editingPassword = ""
    connectAfterSave = andConnect || false
  }

  function closeCredentialsEditor() {
    editingUuid = ""
    editingName = ""
    editingUsername = ""
    editingPassword = ""
    connectAfterSave = false
  }

  function submitCredentials(andConnect) {
    if (!editingUuid) return
    busy = true
    lastError = ""
    credProc.command = ["python3", root.scriptPath, "set-credentials", editingUuid, editingUsername, editingPassword]
    connectAfterSave = andConnect
    credProc.running = true
  }

  function deleteProfile(targetUuid, targetName) {
    if (busy || !targetUuid) return
    busy = true
    actionProc.command = ["python3", root.scriptPath, "delete", targetUuid]
    actionProc.running = true
  }

  function fetchLogs() {
    if (!logsProc.running) {
      logsProc.running = true
    }
  }

  function notifyUser(headline, description, glyph) {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "OpenVPN",
      "-g", glyph || "󰦝",
      "-u", "normal",
      headline,
      description || ""
    ])
  }

  // -------------------------------------------------------------------------
  // Processes & Communication
  // -------------------------------------------------------------------------

  Process {
    id: statusProc
    command: ["python3", root.scriptPath, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        try {
          var data = JSON.parse(text)
          if (data.success) {
            var wasConnected = root.connected
            root.vpns = data.vpns || []
            root.connected = data.connected || false
            root.connecting = data.connecting || false
            root.activeName = data.active_name || ""
            root.activeUuid = data.active_uuid || ""
            root.activeIp = data.active_ip || ""
            root.activeDevice = data.active_device || ""
            root.activeServer = data.active_server || ""

            // Notify on state change to connected
            if (!wasConnected && root.connected && root.activeName) {
              root.notifyUser("OpenVPN Conectado", root.activeName + (root.activeIp ? " (" + root.activeIp + ")" : ""), "󰦝")
            }
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: actionProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        root.busy = false
        try {
          var res = JSON.parse(text)
          if (!res.success) {
            root.lastError = res.error || "Operação falhou"
            if (res.needs_credentials && root.vpns.length > 0) {
              // Find matching VPN and open credential modal
              var targetVpn = null
              for (var i = 0; i < root.vpns.length; i++) {
                if (actionProc.command.indexOf(root.vpns[i].uuid) !== -1 || actionProc.command.indexOf(root.vpns[i].name) !== -1) {
                  targetVpn = root.vpns[i]
                  break
                }
              }
              if (!targetVpn && root.vpns.length > 0) targetVpn = root.vpns[0]
              if (targetVpn) root.openCredentialsEditor(targetVpn, true)
            }
          } else if (res.message) {
            root.lastError = ""
          }
        } catch (e) {}
        root.refresh()
      }
    }
  }

  Process {
    id: credProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        root.busy = false
        try {
          var res = JSON.parse(text)
          if (res.success) {
            var target = root.editingUuid
            var shouldConnect = root.connectAfterSave
            root.closeCredentialsEditor()
            root.refresh()
            if (shouldConnect && target) {
              root.connectVpn(target)
            }
          } else {
            root.lastError = res.error || "Falha ao salvar credenciais"
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: importProc
    command: ["python3", root.scriptPath, "pick-and-import"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        try {
          var res = JSON.parse(text)
          if (res.success) {
            root.notifyUser("Perfil OpenVPN Importado", res.message || res.name, "󰄬")
            root.refresh()
            // Ask for credentials if newly imported profile
            if (res.uuid) {
              root.openCredentialsEditor({ uuid: res.uuid, name: res.name, username: "" }, false)
            }
          } else if (!res.cancelled) {
            root.lastError = res.error || "Falha ao importar perfil"
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: logsProc
    command: ["python3", root.scriptPath, "logs"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function() {
        try {
          var res = JSON.parse(text)
          if (res.success) {
            root.logLines = res.logs || []
          }
        } catch (e) {}
      }
    }
  }

  // Periodic polling timer
  Timer {
    id: pollTimer
    interval: root.opened || root.connecting ? 3000 : 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // -------------------------------------------------------------------------
  // Bar Button Representation
  // -------------------------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.statusSummary

    iconComponent: Component {
      Item {
        anchors.centerIn: parent
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas

        Text {
          id: barIconGlyph
          anchors.centerIn: parent
          text: "󰦝"
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          color: root.connected ? root.accent : (root.connecting ? Color.urgent : root.dim)
          opacity: root.connecting ? (pulseAnim.running ? pulseVal : 1.0) : (root.connected ? 1.0 : 0.75)

          property real pulseVal: 0.5
          SequentialAnimation on opacity {
            id: pulseAnim
            running: root.connecting
            loops: Animation.Infinite
            NumberAnimation { from: 0.4; to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 1.0; to: 0.4; duration: 600; easing.type: Easing.InOutQuad }
          }
        }

        // Connection dot
        Rectangle {
          visible: root.connected
          width: Style.space(5)
          height: Style.space(5)
          radius: width / 2
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          color: root.accent
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        root.toggleDefault()
      } else if (buttonCode === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.toggle()
      }
    }
  }

  // -------------------------------------------------------------------------
  // Popup Panel (KeyboardPanel)
  // -------------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight, Style.space(580))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingUuid !== ""

      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.toggleDefault()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: mainColumn
          width: flick.width
          spacing: Style.space(12)
          padding: Style.space(14)

          // -----------------------------------------------------------------
          // 1. Hero / Header
          // -----------------------------------------------------------------
          PanelHero {
            id: hero
            width: parent.width - mainColumn.padding * 2
            title: "OpenVPN"
            meta: root.connected
              ? ("CONECTADO · " + (root.activeName || "VPN"))
              : (root.connecting ? "CONECTANDO..." : "DESCONECTADO")
            detail: root.connected && root.activeIp ? root.activeIp : (root.vpns.length > 0 ? (root.vpns.length + (root.vpns.length === 1 ? " perfil" : " perfis")) : "")

            iconComponent: Component {
              BorderSurface {
                width: Style.space(38)
                height: Style.space(38)
                radius: Style.cornerRadius
                color: root.connected ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
                borderSpec: Border.controlSpec(root.connected ? "selected" : "normal", root.foreground, root.accent)

                Text {
                  anchors.centerIn: parent
                  text: "󰦝"
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(20)
                  color: root.connected ? root.accent : root.foreground
                }
              }
            }

            trailingControl: Component {
              ToggleSwitch {
                checked: root.connected
                busy: root.busy || root.connecting
                interactive: !root.busy
                onToggled: root.toggleDefault()
              }
            }
          }

          PanelSeparator {
            width: parent.width - mainColumn.padding * 2
            foreground: root.foreground
          }

          // -----------------------------------------------------------------
          // 2. Error / Notice Banner
          // -----------------------------------------------------------------
          BorderSurface {
            visible: root.lastError !== ""
            width: parent.width - mainColumn.padding * 2
            radius: Style.cornerRadius
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.15)
            borderSpec: Border.flat(root.urgent, 1)
            implicitHeight: errRow.implicitHeight + Style.space(16)

            RowLayout {
              id: errRow
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: "󰅖"
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.urgent
              }

              Text {
                Layout.fillWidth: true
                text: root.lastError
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                wrapMode: Text.Wrap
              }

              Button {
                iconText: "󰅖"
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(4)
                onClicked: root.lastError = ""
              }
            }
          }

          // -----------------------------------------------------------------
          // 3. Inline Credentials Editor
          // -----------------------------------------------------------------
          BorderSurface {
            id: credCard
            visible: root.editingUuid !== ""
            width: parent.width - mainColumn.padding * 2
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("hover-cursor", root.foreground, root.accent)
            implicitHeight: credCol.implicitHeight + Style.space(20)

            Column {
              id: credCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              RowLayout {
                width: parent.width
                Text {
                  Layout.fillWidth: true
                  text: "Credenciais: " + root.editingName
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  color: root.foreground
                  elide: Text.ElideRight
                }
                Button {
                  iconText: "󰅖"
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(2)
                  onClicked: root.closeCredentialsEditor()
                }
              }

              Text {
                text: "Usuário"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }

              TextField {
                id: userInput
                width: parent.width
                text: root.editingUsername
                placeholderText: "Ex: usuario"
                onTextChanged: root.editingUsername = text
              }

              Text {
                text: "Senha"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }

              TextField {
                id: passInput
                width: parent.width
                password: true
                text: root.editingPassword
                placeholderText: "Digite sua senha"
                onTextChanged: root.editingPassword = text
                onAccepted: root.submitCredentials(true)
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  Layout.fillWidth: true
                  text: "Salvar e Conectar"
                  iconText: "󰄬"
                  bordered: true
                  accent: root.accent
                  onClicked: root.submitCredentials(true)
                }

                Button {
                  text: "Salvar"
                  bordered: true
                  onClicked: root.submitCredentials(false)
                }

                Button {
                  text: "Cancelar"
                  onClicked: root.closeCredentialsEditor()
                }
              }
            }
          }

          // -----------------------------------------------------------------
          // 4. Profiles Section Header
          // -----------------------------------------------------------------
          RowLayout {
            width: parent.width - mainColumn.padding * 2

            PanelSectionHeader {
              text: "PERFIS CONFIGURADOS"
              foreground: root.foreground
              Layout.fillWidth: true
            }

            Text {
              visible: root.busy
              text: "󰁪 Processando..."
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.dim
            }
          }

          // Empty state placeholder
          BorderSurface {
            visible: root.vpns.length === 0
            width: parent.width - mainColumn.padding * 2
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, root.accent)
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            implicitHeight: emptyCol.implicitHeight + Style.space(24)

            Column {
              id: emptyCol
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              spacing: Style.space(8)

              Text {
                text: "󰦝"
                font.family: root.fontFamily
                font.pixelSize: Style.space(28)
                color: root.dim
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                text: "Nenhuma conexão OpenVPN encontrada"
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                color: root.foreground
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }

              Text {
                text: "Clique no botão '+ Importar .ovpn' abaixo para adicionar seu arquivo de configuração."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }
            }
          }

          // -----------------------------------------------------------------
          // 5. VPN Profiles List
          // -----------------------------------------------------------------
          Repeater {
            model: root.vpns

            delegate: BorderSurface {
              id: profileCard
              readonly property var vpnItem: modelData
              readonly property bool isCurrent: vpnItem.active === true
              width: mainColumn.width - mainColumn.padding * 2
              radius: Style.cornerRadius
              color: isCurrent
                ? Style.selectedFillFor(root.foreground, root.accent)
                : (cardMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent))
              borderSpec: Border.controlSpec(isCurrent ? "selected" : (cardMouse.containsMouse ? "hover-cursor" : "normal"), root.foreground, root.accent)
              implicitHeight: cardRow.implicitHeight + Style.space(16)

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }

              RowLayout {
                id: cardRow
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(10)

                // Status indicator pill / dot
                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  color: profileCard.isCurrent ? root.accent : root.dim
                  Layout.alignment: Qt.AlignVCenter
                }

                // Info: Name & details
                Column {
                  Layout.fillWidth: true
                  spacing: Style.space(2)

                  RowLayout {
                    spacing: Style.space(6)
                    Text {
                      text: profileCard.vpnItem.name
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: profileCard.isCurrent
                      color: profileCard.isCurrent ? root.accent : root.foreground
                      elide: Text.ElideRight
                      Layout.maximumWidth: Style.space(160)
                    }

                    Rectangle {
                      visible: profileCard.isCurrent
                      implicitWidth: badgeTxt.implicitWidth + Style.space(8)
                      implicitHeight: badgeTxt.implicitHeight + Style.space(2)
                      radius: Style.cornerRadius
                      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.2)
                      border.color: root.accent
                      border.width: 1

                      Text {
                        id: badgeTxt
                        anchors.centerIn: parent
                        text: "Ativo"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        color: root.accent
                      }
                    }
                  }

                  Text {
                    text: {
                      var parts = []
                      if (profileCard.vpnItem.ip) parts.push(profileCard.vpnItem.ip)
                      else if (profileCard.vpnItem.server) parts.push(profileCard.vpnItem.server)
                      if (profileCard.vpnItem.username) parts.push("usuário: " + profileCard.vpnItem.username)
                      return parts.join(" · ")
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                // Action buttons
                Row {
                  spacing: Style.space(4)
                  Layout.alignment: Qt.AlignVCenter

                  Button {
                    text: profileCard.isCurrent ? "Desconectar" : "Conectar"
                    iconText: profileCard.isCurrent ? "󰅖" : "󰄬"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(5)
                    bordered: true
                    accent: root.accent
                    selected: profileCard.isCurrent
                    onClicked: {
                      if (profileCard.isCurrent) {
                        root.disconnectVpn(profileCard.vpnItem.uuid)
                      } else {
                        if (profileCard.vpnItem.has_saved_password) {
                          root.connectVpn(profileCard.vpnItem.uuid)
                        } else {
                          root.openCredentialsEditor(profileCard.vpnItem, true)
                        }
                      }
                    }
                  }

                  // Edit credentials button
                  Button {
                    iconText: "󰌆"
                    tooltipText: "Configurar Credenciais"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(5)
                    bordered: true
                    onClicked: root.openCredentialsEditor(profileCard.vpnItem, false)
                  }

                  // Delete button
                  Button {
                    iconText: "󰆴"
                    tooltipText: "Excluir Conexão"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6)
                    verticalPadding: Style.space(5)
                    bordered: true
                    foreground: root.urgent
                    onClicked: root.deleteProfile(profileCard.vpnItem.uuid, profileCard.vpnItem.name)
                  }
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width - mainColumn.padding * 2
            foreground: root.foreground
          }

          // -----------------------------------------------------------------
          // 6. Action Toolbar
          // -----------------------------------------------------------------
          RowLayout {
            width: parent.width - mainColumn.padding * 2
            spacing: Style.space(8)

            Button {
              Layout.fillWidth: true
              text: "+ Importar .ovpn"
              iconText: "󰒘"
              fontSize: Style.font.bodySmall
              bordered: true
              accent: root.accent
              onClicked: root.importOvpn()
            }

            Button {
              text: "Atualizar"
              iconText: "󰁪"
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.refresh()
            }

            Button {
              text: root.showLogs ? "Ocultar Logs" : "Logs"
              iconText: "󰠮"
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: {
                root.showLogs = !root.showLogs
                if (root.showLogs) root.fetchLogs()
              }
            }
          }

          // -----------------------------------------------------------------
          // 7. Logs Drawer (Collapsible)
          // -----------------------------------------------------------------
          BorderSurface {
            visible: root.showLogs
            width: parent.width - mainColumn.padding * 2
            radius: Style.cornerRadius
            color: Color.popups.background
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            implicitHeight: logsCol.implicitHeight + Style.space(16)

            Column {
              id: logsCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                Text {
                  text: "Últimos Logs do OpenVPN"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.dim
                  Layout.fillWidth: true
                }
                Button {
                  iconText: "󰁪"
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(2)
                  onClicked: root.fetchLogs()
                }
              }

              Flickable {
                width: parent.width
                height: Style.space(120)
                contentWidth: width
                contentHeight: logsText.implicitHeight
                clip: true

                Text {
                  id: logsText
                  width: parent.width
                  text: root.logLines.length > 0 ? root.logLines.join("\n") : "Nenhum log recente disponível."
                  font.family: "monospace"
                  font.pixelSize: Style.space(10)
                  color: root.foreground
                  wrapMode: Text.Wrap
                }
              }
            }
          }

        }
      }
    }
  }
}
