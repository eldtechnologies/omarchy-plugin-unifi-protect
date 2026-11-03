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
  property string cli: ""
  // Stream URLs the helper handed out after wall.json was written (say, after
  // a relay restart), by "<uid>|<quality>"; shared by every view of a camera.
  property var freshUrls: ({})

  function setFreshUrl(key, url) {
    var copy = Object.assign({}, freshUrls)
    copy[key] = url
    freshUrls = copy
  }
  property string gridQuality: "low"
  property string focusQuality: "high"
  readonly property MediaDevices mediaDevices: MediaDevices {}

  readonly property int count: cameras.length
  readonly property var focusedCamera: focusedIndex >= 0 ? cameras[focusedIndex] : null

  // ---- layouts ----
  //
  // The same names as the helper's --layout (WALL_LAYOUT there); keep the
  // two in step. A layout is a grid of `cols` x `rows` cells and the tiles
  // on it, each spanning w x h cells from (x, y). Cameras beyond the tiles
  // go on further pages.
  readonly property var layoutNames: ["auto", "row", "column", "1x1", "2x2", "3x3", "4x4", "1+5", "1+7"]
  property string layoutName: "auto"
  // What G cycles through: the presets, plus the configured layout if it
  // is none of them (say, 2x4).
  property var layoutCycle: layoutNames
  // The wall's size, for "auto" to fit the screen's shape.
  property real viewWidth: 16
  property real viewHeight: 9

  function validLayout(name) {
    name = String(name || "").trim().toLowerCase()
    return /^(auto|row|column|[1-6]x[1-6]|1\+[57])$/.test(name) ? name : "auto"
  }

  function uniformLayout(cols, rows) {
    var cells = []
    for (var i = 0; i < cols * rows; i++)
      cells.push({ x: i % cols, y: Math.floor(i / cols), w: 1, h: 1 })
    return { cols: cols, rows: rows, cells: cells }
  }

  // Landscape: the grid the wall always had (2x2 up to 4 cameras, 3x3 up to
  // 9, 4x4 up to 16, then 5 columns). Portrait: the columns that make n
  // 16:9 tiles largest, ties going to fewer empty cells, then fewer columns;
  // a single column up to 6 cameras on a 9:16 monitor.
  function autoColumns(n, w, h) {
    if (n <= 1) return 1
    w = w > 0 ? w : 16
    h = h > 0 ? h : 9
    if (w >= h) return n <= 4 ? 2 : n <= 9 ? 3 : n <= 16 ? 4 : 5
    var best = 1, bestArea = -1, bestEmpty = 0
    for (var c = 1; c <= n; c++) {
      var r = Math.ceil(n / c)
      var tileW = Math.min(w / c, (h / r) * 16 / 9)
      var area = tileW * tileW * 9 / 16
      var empty = c * r - n
      var better = area > bestArea * 1.01
                   || (area >= bestArea * 0.99
                       && empty < bestEmpty)
      if (better) { best = c; bestArea = Math.max(area, bestArea); bestEmpty = empty }
    }
    return best
  }

  function computeLayout(name, n, w, h) {
    n = Math.max(1, n)
    if (name === "row") return uniformLayout(n, 1)
    if (name === "column") return uniformLayout(1, n)
    if (name === "1+5")
      return { cols: 3, rows: 3, cells: [{ x: 0, y: 0, w: 2, h: 2 },
        { x: 2, y: 0, w: 1, h: 1 }, { x: 2, y: 1, w: 1, h: 1 },
        { x: 0, y: 2, w: 1, h: 1 }, { x: 1, y: 2, w: 1, h: 1 }, { x: 2, y: 2, w: 1, h: 1 }] }
    if (name === "1+7")
      return { cols: 4, rows: 4, cells: [{ x: 0, y: 0, w: 3, h: 3 },
        { x: 3, y: 0, w: 1, h: 1 }, { x: 3, y: 1, w: 1, h: 1 }, { x: 3, y: 2, w: 1, h: 1 },
        { x: 0, y: 3, w: 1, h: 1 }, { x: 1, y: 3, w: 1, h: 1 }, { x: 2, y: 3, w: 1, h: 1 },
        { x: 3, y: 3, w: 1, h: 1 }] }
    var grid = /^([1-6])x([1-6])$/.exec(name)
    if (grid) return uniformLayout(Number(grid[1]), Number(grid[2]))
    var cols = autoColumns(n, w, h)
    return uniformLayout(cols, Math.ceil(n / cols))
  }

  readonly property var layout: computeLayout(layoutName, count, viewWidth, viewHeight)
  readonly property int pageSize: Math.max(1, layout.cells.length)
  readonly property int pageCount: Math.max(1, Math.ceil(count / pageSize))
  // The grid's page follows the selection, which stands still while a
  // camera is enlarged: flipping through cameras then does not reload the
  // grid behind it.
  readonly property int page: Math.floor(selectedIndex / pageSize)
  readonly property int pageStart: page * pageSize
  // Ints for the bounds, so a resize (which can reshape "auto", always a
  // single page) does not reload the tiles: only a different set of
  // cameras does.
  readonly property int pageEnd: Math.min(count, pageStart + pageSize)
  readonly property var pageCameras: cameras.slice(pageStart, pageEnd)
  readonly property string layoutLabel: layoutName === "auto"
                                        ? "auto " + layout.cols + "x" + layout.rows : layoutName

  function cycleLayout(step) {
    var i = layoutCycle.indexOf(layoutName)
    layoutName = layoutCycle[(i + step + layoutCycle.length) % layoutCycle.length]
  }

  function turnPage(step) {
    if (pageCount <= 1) return
    selectedIndex = ((page + step + pageCount) % pageCount) * pageSize
  }

  function focusCamera(index) {
    if (index < 0 || index >= count) return
    // Enlarging from the grid starts at the default; M carries over while
    // flipping between cameras.
    if (focusedIndex < 0) muted = !soundDefault
    // A camera with no stream is not enlarged: the grid shows its error.
    if (focusedIndex < 0 || cameras[index].error) selectedIndex = index
    focusedIndex = cameras[index].error ? -1 : index
  }

  // Back to the grid, on the page of the camera last enlarged.
  function showGrid() {
    if (focusedIndex >= 0) selectedIndex = focusedIndex
    focusedIndex = -1
  }

  function move(dx, dy) {
    if (count === 0) return
    if (focusedIndex >= 0) {
      // Left/right flips through cameras while one is enlarged.
      if (dx !== 0) focusCamera((focusedIndex + dx + count) % count)
      return
    }
    // The nearest tile that way which lines up with this one: tiles can
    // span several cells (1+5, 1+7), so index arithmetic would not do.
    var cells = layout.cells
    var local = selectedIndex - pageStart
    var here = cells[local]
    var best = -1, bestScore = 0
    for (var i = 0; here && i < pageEnd - pageStart; i++) {
      var c = cells[i]
      if (i === local || !c) continue
      // The gap from this tile's edge to that one's; behind it is no move.
      var gap = dx > 0 ? c.x - (here.x + here.w) : dx < 0 ? here.x - (c.x + c.w)
              : dy > 0 ? c.y - (here.y + here.h) : here.y - (c.y + c.h)
      // Lining up: sharing rows for a sideways move, columns for up/down.
      var shared = dx !== 0 ? Math.min(here.y + here.h, c.y + c.h) - Math.max(here.y, c.y)
                            : Math.min(here.x + here.w, c.x + c.w) - Math.max(here.x, c.x)
      if (gap < 0 || shared <= 0) continue
      var offset = dx !== 0 ? Math.abs(c.y + c.h / 2 - here.y - here.h / 2)
                            : Math.abs(c.x + c.w / 2 - here.x - here.w / 2)
      var score = gap * 100 + offset
      if (best < 0 || score < bestScore) { best = i; bestScore = score }
    }
    if (best >= 0) {
      selectedIndex = pageStart + best
    } else if (dx !== 0) {
      // Off the end of a row: on to the next camera, across pages.
      var step = selectedIndex + dx
      var cell = cells[step - pageStart]
      // ...unless the next one is a row below or above in the same page that
      // is not the start or end of a row (a big tile's neighbours, a part
      // filled last row): then stay.
      if (step >= 0 && step < count
          && (step < pageStart || step >= pageEnd
              || (dx > 0 ? cell.x === 0 : cell.x + cell.w === layout.cols)))
        selectedIndex = step
    } else {
      // Off the top or bottom: the same tile on the page before or after.
      var next = selectedIndex + dy * pageSize
      if (next >= 0 && page + dy < pageCount) selectedIndex = Math.min(count - 1, next)
    }
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
        shell.cli = data.cli || ""
        shell.gridQuality = data.gridQuality || "low"
        shell.focusQuality = data.focusQuality || "high"
        shell.layoutName = shell.validLayout(data.layout)
        if (shell.layoutNames.indexOf(shell.layoutName) < 0)
          shell.layoutCycle = [shell.layoutNames[0], shell.layoutName].concat(shell.layoutNames.slice(1))
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
    property string url: ""          // from wall.json; stays bound
    property string uid: ""
    property string quality: ""
    readonly property string key: uid + "|" + quality
    readonly property string playUrl: shell.freshUrls[key] || url
    property int failures: 0
    property bool counted: false
    property string snapshot: ""
    property bool playAudio: false
    readonly property bool live: player.playbackState === MediaPlayer.PlayingState
                                 && player.mediaStatus !== MediaPlayer.LoadingMedia
                                 && player.mediaStatus !== MediaPlayer.StalledMedia
    property string error: ""

    function start() {
      if (playUrl === "") return
      counted = false
      // Setting the same URL again would not reconnect: the player resumes
      // its dead stream, reports it as buffered and freezes. Clear it first.
      player.source = ""
      player.source = playUrl
      player.play()
    }

    // One failed attempt can be reported twice (an error, then a status).
    function failed(message) {
      if (message) error = message
      if (counted) return
      counted = true
      failures++
      // 3 s, doubling up to a minute while it keeps failing.
      retry.interval = Math.min(60000, 3000 * Math.pow(2, Math.max(0, failures - 1)))
      retry.restart()
    }

    // Another camera (the enlarged view flips) starts afresh.
    onKeyChanged: { failures = 0; retry.stop() }
    onPlayUrlChanged: start()
    Component.onCompleted: start()

    // A frame to look at while the stream connects.
    Image {
      anchors.fill: parent
      visible: !stream.live && stream.snapshot !== ""
      source: stream.snapshot
      // Decoded at tile size, whatever size the console's JPEG claims.
      sourceSize.width: 1280
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
      // Follow the system default if it changes while the wall is up.
      device: shell.mediaDevices.defaultAudioOutput
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
        stream.failed(errorString || "stream failed")
      }
      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.EndOfMedia || mediaStatus === MediaPlayer.InvalidMedia) {
          stream.failed("")
        } else if (mediaStatus === MediaPlayer.BufferedMedia) {
          stream.error = ""
          stream.failures = 0
        }
      }
    }

    // Cameras drop their stream on firmware updates, Wi-Fi hiccups and
    // console restarts. A wall left running should heal itself.
    Timer {
      id: retry
      interval: 3000
      onTriggered: {
        player.stop()
        // Twice in a row: the URL itself may be stale (the relay restarted
        // with a new port and token). Ask the helper for a fresh one rather
        // than knocking on a port that is no longer ours.
        if (stream.failures >= 2 && shell.cli !== "" && stream.uid !== "" && !refresh.running) {
          refresh.forKey = stream.key
          refresh.stale = stream.playUrl
          refresh.command = [shell.cli, "stream", stream.uid, "--quality", stream.quality]
          refresh.running = true
        } else {
          stream.start()
        }
      }
    }

    Process {
      id: refresh
      property string forKey: ""
      property string stale: ""
      stdout: StdioCollector { id: refreshOut }
      onExited: function(exitCode) {
        // The view moved on to another camera meanwhile: not ours to use.
        if (forKey !== stream.key) return
        var fresh = refreshOut.text.trim()
        if (exitCode === 0 && fresh.indexOf("rtsp://127.0.0.1:") === 0 && fresh !== stale)
          shell.setFreshUrl(forKey, fresh)      // playUrl changes and starts it
        else
          stream.start()
      }
    }

    Text {
      // Console text: never let Qt read it as HTML (an <img> would load).
      textFormat: Text.PlainText
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

    Binding { target: shell; property: "viewWidth"; value: keys.width }
    Binding { target: shell; property: "viewHeight"; value: keys.height }

    Keys.onPressed: function(event) {
      hintTimer.restart()
      var text = event.text.toLowerCase()
      if (event.key === Qt.Key_Escape || text === "q") {
        if (shell.focusedIndex >= 0 && text !== "q") shell.showGrid()
        else Qt.quit()
      } else if (event.key === Qt.Key_Left || text === "h") shell.move(-1, 0)
      else if (event.key === Qt.Key_Right || text === "l") shell.move(1, 0)
      else if (event.key === Qt.Key_Up || text === "k") shell.move(0, -1)
      else if (event.key === Qt.Key_Down || text === "j") shell.move(0, 1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        if (shell.focusedIndex >= 0) shell.showGrid()
        else shell.focusCamera(shell.selectedIndex)
      }
      else if (text === "m") shell.muted = !shell.muted
      // Layout and page keys reload streams: one step per press, never a
      // held key's repeats.
      else if (text === "g" && shell.focusedIndex < 0) {
        if (!event.isAutoRepeat) shell.cycleLayout(event.modifiers & Qt.ShiftModifier ? -1 : 1)
      }
      else if ((event.key === Qt.Key_PageDown || text === "]") && shell.focusedIndex < 0) {
        if (!event.isAutoRepeat) shell.turnPage(1)
      }
      else if ((event.key === Qt.Key_PageUp || text === "[") && shell.focusedIndex < 0) {
        if (!event.isAutoRepeat) shell.turnPage(-1)
      }
      else if (text >= "1" && text <= "9") {
        // In the grid, the number on the tile, on the page shown; enlarged,
        // the Nth camera, as the grid's own numbering is out of sight.
        if (shell.focusedIndex >= 0) shell.focusCamera(Number(text) - 1)
        else if (Number(text) <= shell.pageEnd - shell.pageStart)
          shell.focusCamera(shell.pageStart + Number(text) - 1)
      }
      else if (text === "0") shell.showGrid()
      else return
      event.accepted = true
    }

    // ---- grid ----
    // Stays mounted while a camera is enlarged, so going back is instant
    // rather than a reconnect of every stream.
    // Only the page shown is mounted: a camera on another page costs no
    // decoder.
    Item {
      id: grid
      anchors.fill: parent
      visible: shell.focusedIndex < 0
      readonly property real spacing: 2
      // One cell plus the gap after it; a tile spans whole cells, less the
      // last gap.
      readonly property real cellWidth: (width + spacing) / shell.layout.cols
      readonly property real cellHeight: (height + spacing) / shell.layout.rows

      Repeater {
        model: shell.pageCameras

        Rectangle {
          id: tile
          required property var modelData
          required property int index
          readonly property int cameraIndex: shell.pageStart + index
          readonly property var cell: shell.layout.cells[index] || { x: 0, y: 0, w: 1, h: 1 }
          x: cell.x * grid.cellWidth
          y: cell.y * grid.cellHeight
          width: cell.w * grid.cellWidth - grid.spacing
          height: cell.h * grid.cellHeight - grid.spacing
          color: "#0b0b0b"
          border.width: cameraIndex === shell.selectedIndex && hintTimer.running ? 2 : 0
          border.color: "#ffffff"

          Stream {
            anchors.fill: parent
            anchors.margins: tile.border.width
            url: tile.modelData.grid || ""
            uid: tile.modelData.uid || ""
            quality: shell.gridQuality
            snapshot: shell.snapshotDir ? "file://" + shell.snapshotDir + "/" + tile.modelData.uid + ".jpg" : ""
          }

          Text {
            textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
            onPositionChanged: { shell.selectedIndex = tile.cameraIndex; hintTimer.restart() }
            onClicked: shell.focusCamera(tile.cameraIndex)
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
          uid: shell.focusedCamera ? shell.focusedCamera.uid : ""
          quality: shell.focusedCamera && shell.focusedCamera.focus ? shell.focusQuality : shell.gridQuality
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
            textFormat: Text.PlainText
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
          onClicked: shell.showGrid()
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
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: shell.focusedIndex >= 0
              ? "←/→ next camera  ·  M mute  ·  Esc or click back to grid  ·  Q close"
              : "Click, Enter or " + (shell.pageEnd - shell.pageStart > 1
                                       ? "1–" + Math.min(9, shell.pageEnd - shell.pageStart) : "1")
                + " enlarge  ·  G layout " + shell.layoutLabel
                + (shell.pageCount > 1 ? "  ·  PgDn page " + (shell.page + 1) + "/" + shell.pageCount : "")
                + "  ·  Esc close"
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
