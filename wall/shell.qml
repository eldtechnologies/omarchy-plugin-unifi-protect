import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Live wall of every online camera, maximized or full-screen.
//
// Runs as its own Quickshell process, started by `eld-unifi-protect wall`,
// never inside omarchy-shell: eight concurrent RTSPS decoders are the
// heaviest thing this plugin does, and a decoder fault here must not take the
// bar or the lock screen down with it.
//
// The CLI resolves stream URLs and writes them to $ELD_UNIFI_PROTECT_WALL; this
// file only plays them.
ShellRoot {
  id: shell

  property var cameras: []
  property string snapshotDir: ""
  property bool multiConsole: false
  property int focusedIndex: -1
  property int selectedIndex: 0
  property bool muted: true
  // Sound for an enlarged camera (the bar's "sound" setting); tiles are silent.
  property bool soundDefault: true

  readonly property int count: cameras.length
  readonly property int columns: count <= 1 ? 1 : count <= 4 ? 2 : count <= 9 ? 3 : count <= 16 ? 4 : 5
  readonly property int rows: Math.max(1, Math.ceil(count / columns))
  readonly property var focusedCamera: focusedIndex >= 0 ? cameras[focusedIndex] : null

  function focusCamera(index) {
    if (index < 0 || index >= count) return
    selectedIndex = index
    // Enlarging from the grid starts at the default; M carries over while
    // flipping between cameras.
    if (focusedIndex < 0) muted = !soundDefault
    focusedIndex = cameras[index].error ? -1 : index
  }

  function move(dx, dy) {
    if (count === 0) return
    if (focusedIndex >= 0) {
      // Left/right flips through cameras while one is enlarged.
      if (dx !== 0) focusCamera((focusedIndex + dx + count) % count)
      return
    }
    var next = selectedIndex + dx + dy * columns
    selectedIndex = Math.max(0, Math.min(count - 1, next))
  }

  FileView {
    path: Quickshell.env("ELD_UNIFI_PROTECT_WALL") || ""
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text())
        shell.snapshotDir = data.snapshotDir || ""
        shell.multiConsole = data.multiConsole === true
        shell.soundDefault = data.sound !== false
        shell.cameras = data.cameras || []
      } catch (error) {
        Qt.quit()
      }
    }
    onLoadFailed: Qt.quit()
  }

  // Hides the key hints a few seconds after the last keypress or move.
  Timer {
    id: hintTimer
    interval: 4000
    running: true
  }

  component Stream: Item {
    id: stream
    property string url: ""
    property string snapshot: ""
    property bool playAudio: false
    readonly property bool live: player.playbackState === MediaPlayer.PlayingState
                                 && player.mediaStatus !== MediaPlayer.LoadingMedia
                                 && player.mediaStatus !== MediaPlayer.StalledMedia
    property string error: ""

    function start() {
      if (url === "") return
      player.source = url
      player.play()
    }

    onUrlChanged: start()
    Component.onCompleted: start()

    // A frame to look at while the stream connects.
    Image {
      anchors.fill: parent
      visible: !stream.live && stream.snapshot !== ""
      source: stream.snapshot
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: false
      opacity: 0.5
    }

    VideoOutput {
      id: video
      anchors.fill: parent
      fillMode: VideoOutput.PreserveAspectFit
    }

    AudioOutput {
      id: audio
      muted: shell.muted
    }

    MediaPlayer {
      id: player
      videoOutput: video
      // Grid tiles are always silent, so they skip audio entirely (-1 turns
      // the track off) rather than decoding it only to mute it.
      audioOutput: stream.playAudio ? audio : null
      activeAudioTrack: stream.playAudio ? 0 : -1
      // Low-latency mode suits live network streams; for a local file (the
      // demo) it drops every frame, so only RTSP gets it.
      playbackOptions.playbackIntent: String(source).indexOf("rtsp") === 0
                                      ? PlaybackOptions.PlaybackIntent.LowLatencyStreaming
                                      : PlaybackOptions.PlaybackIntent.Playback
      playbackOptions.networkTimeoutMs: 8000
      onErrorOccurred: function(error, errorString) {
        stream.error = errorString || "stream failed"
        retry.restart()
      }
      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.EndOfMedia || mediaStatus === MediaPlayer.InvalidMedia)
          retry.restart()
        else if (mediaStatus === MediaPlayer.BufferedMedia)
          stream.error = ""
      }
    }

    // Cameras drop their stream on firmware updates, Wi-Fi hiccups and
    // console restarts. A wall left running should heal itself.
    Timer {
      id: retry
      interval: 3000
      onTriggered: { player.stop(); stream.start() }
    }

    Text {
      anchors.centerIn: parent
      visible: !stream.live
      text: stream.error !== "" ? stream.error + " · retrying" : "Connecting…"
      color: stream.error !== "" ? "#ff7777" : "#cccccc"
      font.pixelSize: 16
    }
  }

  // ---- contents, shared by both window modes ----
  component WallView: Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onPressed: function(event) {
      hintTimer.restart()
      var text = event.text.toLowerCase()
      if (event.key === Qt.Key_Escape || text === "q") {
        if (shell.focusedIndex >= 0 && text !== "q") shell.focusedIndex = -1
        else Qt.quit()
      } else if (event.key === Qt.Key_Left || text === "h") shell.move(-1, 0)
      else if (event.key === Qt.Key_Right || text === "l") shell.move(1, 0)
      else if (event.key === Qt.Key_Up || text === "k") shell.move(0, -1)
      else if (event.key === Qt.Key_Down || text === "j") shell.move(0, 1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        if (shell.focusedIndex >= 0) shell.focusedIndex = -1
        else shell.focusCamera(shell.selectedIndex)
      }
      else if (text === "m") shell.muted = !shell.muted
      else if (text >= "1" && text <= "9") shell.focusCamera(Number(text) - 1)
      else if (text === "0") shell.focusedIndex = -1
      else return
      event.accepted = true
    }

    // ---- grid ----
    // Stays mounted while a camera is enlarged, so going back is instant
    // rather than a reconnect of every stream.
    Grid {
      id: grid
      anchors.fill: parent
      visible: shell.focusedIndex < 0
      columns: shell.columns
      spacing: 2

      Repeater {
        model: shell.cameras

        Rectangle {
          id: tile
          required property var modelData
          required property int index
          width: (grid.width - grid.spacing * (shell.columns - 1)) / shell.columns
          height: (grid.height - grid.spacing * (shell.rows - 1)) / shell.rows
          color: "#0b0b0b"
          border.width: index === shell.selectedIndex && hintTimer.running ? 2 : 0
          border.color: "#ffffff"

          Stream {
            anchors.fill: parent
            anchors.margins: tile.border.width
            url: tile.modelData.grid || ""
            snapshot: shell.snapshotDir ? "file://" + shell.snapshotDir + "/" + tile.modelData.uid + ".jpg" : ""
          }

          Text {
            anchors.centerIn: parent
            visible: !!tile.modelData.error
            text: tile.modelData.error || ""
            color: "#ff7777"
            font.pixelSize: 16
          }

          Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 10
            width: label.implicitWidth + 16
            height: label.implicitHeight + 8
            radius: 4
            color: Qt.rgba(0, 0, 0, 0.55)

            Text {
              id: label
              anchors.centerIn: parent
              text: (tile.index < 9 ? (tile.index + 1) + "  " : "") + tile.modelData.name
                    + (shell.multiConsole ? "  ·  " + tile.modelData.consoleName : "")
              color: "white"
              font.pixelSize: 14
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: { shell.selectedIndex = tile.index; hintTimer.restart() }
            onClicked: shell.focusCamera(tile.index)
          }
        }
      }
    }

    // ---- one camera, full screen, at the higher quality ----
    Loader {
      anchors.fill: parent
      active: shell.focusedIndex >= 0
      sourceComponent: Item {
        Stream {
          anchors.fill: parent
          url: shell.focusedCamera ? shell.focusedCamera.focus || shell.focusedCamera.grid : ""
          snapshot: shell.focusedCamera && shell.snapshotDir
                    ? "file://" + shell.snapshotDir + "/" + shell.focusedCamera.uid + ".jpg" : ""
          playAudio: true
        }

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.margins: 20
          width: focusLabel.implicitWidth + 24
          height: focusLabel.implicitHeight + 12
          radius: 6
          color: Qt.rgba(0, 0, 0, 0.55)

          Text {
            id: focusLabel
            anchors.centerIn: parent
            text: "● " + (shell.focusedCamera ? shell.focusedCamera.name : "")
                  + (shell.multiConsole && shell.focusedCamera ? "  ·  " + shell.focusedCamera.consoleName : "")
                  + (shell.muted ? "  ·  muted" : "")
            color: "white"
            font.pixelSize: 18
            font.bold: true
          }
        }

        MouseArea {
          anchors.fill: parent
          onClicked: shell.focusedIndex = -1
        }
      }
    }

    // ---- key hints ----
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 24
      width: hints.implicitWidth + 32
      height: hints.implicitHeight + 14
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.7)
      opacity: hintTimer.running ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 300 } }

      Text {
        id: hints
        anchors.centerIn: parent
        text: shell.focusedIndex >= 0
              ? "←/→ next camera  ·  M mute  ·  Esc or click back to grid  ·  Q close"
              : "Click or 1–9 enlarge  ·  arrows select  ·  Enter enlarge  ·  Esc close"
        color: "white"
        font.pixelSize: 14
      }
    }
  }

  // ---- window modes ----
  //
  // "window" (default): an ordinary toplevel that Hyprland manages. The CLI
  // registers a named rule that maximizes it, so it fills the screen but
  // stays on its workspace: Super+number switches away and back, and the
  // bar stays visible.
  //
  // "overlay": a layer-shell surface over everything, every workspace
  // included, with exclusive keyboard focus. A true kiosk, at the cost of
  // workspace switching.
  readonly property string mode: Quickshell.env("ELD_UNIFI_PROTECT_WALL_MODE") === "overlay"
                                  ? "overlay" : "window"

  LazyLoader {
    // Mapped only once the camera list is in, so startup never flashes an
    // empty black screen.
    active: shell.mode === "window" && shell.count > 0

    FloatingWindow {
      // The Hyprland rule matches this title; keep the two in step.
      title: "UniFi Protect Wall"
      color: "black"
      implicitWidth: 1600
      implicitHeight: 900

      WallView { anchors.fill: parent }
    }
  }

  LazyLoader {
    active: shell.mode === "overlay" && shell.count > 0

    PanelWindow {
      screen: {
        var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        for (var i = 0; i < Quickshell.screens.length; i++)
          if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
        return Quickshell.screens[0]
      }
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      WlrLayershell.namespace: "eld-unifi-protect-wall"
      color: "black"

      WallView { anchors.fill: parent }
    }
  }
}
