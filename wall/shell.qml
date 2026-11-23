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
//
// `eld-unifi-protect timeline` starts the same file as a second window of
// its own (through a link the helper makes, with timeline: true in its
// config): the grid above a timeline of the
// last 24 hours. Drag it and every camera shown goes to that moment. The
// wall itself has none of this, so a wall left on a monitor stays a wall.
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

  // ---- timeline ----
  //
  // One clock for every camera shown. Live until the playhead is moved;
  // then `playhead` (Unix seconds) is the moment on screen. While it is
  // dragged (`scrubbing`) tiles show still frames; let go, they play
  // recordings from there in clips of `chunkSeconds`, all cut at the same
  // moments so every tile changes clip together. The helper fetches both
  // (`timeline-serve`), asked over a pipe.
  property bool timeline: false
  property string playbackQuality: "low"
  property var consoleNames: ({})
  property real now: Date.now() / 1000
  property bool reviewing: false
  property real playhead: 0
  property bool scrubbing: false
  property bool paused: false
  property real anchorPlayhead: 0
  property real anchorWall: 0
  // Each settled move of the playhead, for tiles to line up with again.
  property int seekSerial: 0
  // Recordings are not played closer to now than this: the console has
  // not written the last seconds yet (clips are cut `recordLag` short of
  // now), and a clip that close would run out as soon as it started.
  readonly property real liveEdge: 30
  readonly property real recordLag: 8
  readonly property real reach: 24 * 3600
  readonly property int chunkSeconds: 60
  readonly property real chunkStart: Math.floor(playhead / chunkSeconds) * chunkSeconds
  // The stretch of time the lanes show: `span` seconds ending at viewEnd,
  // or at now (and following it) while viewEnd is 0.
  property real span: 6 * 3600
  property real viewEnd: 0
  readonly property real viewEndTime: viewEnd > 0 ? viewEnd : now
  readonly property real viewStart: viewEndTime - span
  readonly property var spans: [3600, 6 * 3600, 24 * 3600]
  // Per camera uid: where footage exists and what was detected.
  property var index: ({})
  property bool indexLoaded: false
  readonly property var laneCameras: focusedIndex >= 0 && focusedCamera ? [focusedCamera] : pageCameras

  readonly property var kindColors: ({
    person: "#ffb454", face: "#ffb454", vehicle: "#59c2ff", licensePlate: "#59c2ff",
    animal: "#aad94c", package: "#d2a6ff", ring: "#ff6f91", audio: "#95e6cb", motion: "#5f7488"
  })

  function clockText(seconds, withDay) {
    return Qt.formatDateTime(new Date(seconds * 1000), withDay ? "ddd HH:mm:ss" : "HH:mm:ss")
  }

  function spanText(seconds) {
    return seconds >= 3600 ? Math.round(seconds / 360) / 10 + " h" : Math.round(seconds / 60) + " min"
  }

  function seekTo(time, settled) {
    var current = Date.now() / 1000
    if (time >= current - liveEdge) {
      // Let go at the right-hand end: back to live.
      if (settled) { goLive(); return }
      time = current - liveEdge
    }
    // Before the playhead moves and before `reviewing`: tiles must not
    // fetch a clip for a playhead that is still being dragged, and what
    // they ask for a settled move must carry that move's number.
    if (!settled) scrubbing = true
    else seekSerial++
    playhead = Math.max(current - reach + 60, time)
    reviewing = true
    if (settled) settle()
  }

  function settle() {
    settleTimer.stop()
    // Stepped or dragged up to the end: that is live. (The end has moved
    // on a little since the playhead was put there.)
    if (playhead >= Date.now() / 1000 - liveEdge - 5) { goLive(); return }
    // The move's number first: tiles ask for clips as scrubbing ends.
    seekSerial++
    scrubbing = false
    anchorPlayhead = playhead
    anchorWall = Date.now()
    keepInView()
  }

  function stepBy(seconds) {
    if (!reviewing && seconds > 0) return
    seekTo((reviewing ? playhead : Date.now() / 1000 - liveEdge) + seconds, false)
    keepInView()
    // Settled when the key is let go (stepReleased); this is for a release
    // that never arrives, say because the window lost the keyboard.
    settleTimer.interval = 1500
    settleTimer.restart()
  }

  function stepReleased() {
    if (!scrubbing || !settleTimer.running) return
    settleTimer.interval = 150
    settleTimer.restart()
  }

  function goLive() {
    settleTimer.stop()
    reviewing = false
    scrubbing = false
    paused = false
    viewEnd = 0
  }

  function togglePause() {
    if (!reviewing) {
      // Freeze what was just on screen.
      playhead = Date.now() / 1000 - liveEdge - 10
      reviewing = true
      paused = true
      settle()
      return
    }
    paused = !paused
    if (!paused) {
      anchorPlayhead = playhead
      anchorWall = Date.now()
    }
  }

  function setViewEnd(end) {
    end = Math.max(end, now - reach + span)
    viewEnd = end >= now - 1 ? 0 : end
  }

  function keepInView() {
    if (reviewing && (playhead < viewStart || playhead > viewEndTime)) setViewEnd(playhead + span / 2)
  }

  // Zoom to `seconds` across, the moment at `pivot` staying where it is.
  function setSpan(seconds, pivot) {
    seconds = Math.max(600, Math.min(reach, seconds))
    var end = pivot + (viewEndTime - pivot) / span * seconds
    span = seconds
    setViewEnd(end)
  }

  function zoomStep(step) {
    // The next preset that way from wherever the wheel left the span.
    var next = span
    for (var i = 0; i < spans.length; i++) {
      var preset = spans[step < 0 ? spans.length - 1 - i : i]
      if (step < 0 ? preset < span - 1 : preset > span + 1) { next = preset; break }
    }
    if (next === span) return
    setSpan(next, reviewing ? playhead : now)
    // The playhead in the middle, where there is room to move both ways.
    if (reviewing) setViewEnd(playhead + next / 2)
  }

  // The detection before or after the playhead, on any camera shown.
  function jumpEvent(step) {
    var from = reviewing ? playhead : now
    var best = null
    for (var c = 0; c < laneCameras.length; c++) {
      var info = index[laneCameras[c].uid]
      var events = info && info.events ? info.events : []
      for (var i = 0; i < events.length; i++) {
        if (events[i].kind === "motion") continue
        var start = events[i].start - 3
        if (start < now - reach + 60) continue      // older than can be shown
        if (step < 0 ? start < from - 5 : start > from + 1)
          if (best === null || (step < 0 ? start > best : start < best)) best = start
      }
    }
    if (best !== null) seekTo(best, true)
  }

  // ---- keeping a stretch of a recording ----
  //
  // Dragging along the timeline, or I and O, marks where it starts and
  // ends; S saves it, for the camera enlarged or selected, to the videos
  // folder. Without marks S saves the half minute around the playhead.
  property real markIn: -1
  property real markOut: -1
  property bool saving: false
  property string saveNote: ""
  property bool saveFailed: false
  readonly property int saveLimit: 600
  readonly property var saveCamera: focusedIndex >= 0 ? focusedCamera : (cameras[selectedIndex] || null)

  function mark(end) {
    if (!reviewing) return
    if (end) {
      markOut = playhead
      if (markIn >= markOut) markIn = -1
    } else {
      markIn = playhead
      if (markOut >= 0 && markOut <= markIn) markOut = -1
    }
  }

  // Both marks at once, from a drag: either end may be the later one.
  function markBetween(one, other) {
    var current = Date.now() / 1000
    var from = Math.max(current - reach + 60, Math.min(one, other))
    var to = Math.min(current - liveEdge, Math.max(one, other))
    if (to <= from) return
    markIn = from
    markOut = to
  }

  function clearMarks() {
    markIn = -1
    markOut = -1
  }

  function saveSaid(text, failed) {
    saveNote = text
    saveFailed = failed
    saveNoteTimer.restart()
  }

  function saveClip() {
    var camera = saveCamera
    // A marked stretch can be saved from live too: dragging up to the
    // right-hand end marks it and goes back to live.
    var marked = markIn >= 0 && markOut >= 0
    if (saving || (!reviewing && !marked) || !camera || !backendReady) return
    var start = markIn >= 0 ? markIn : markOut >= 0 ? playhead : playhead - 15
    var end = markOut >= 0 ? markOut : markIn >= 0 ? playhead : playhead + 15
    // Nothing later than the console has written.
    end = Math.min(end, Date.now() / 1000 - recordLag)
    if (end - start < 1) {
      saveSaid("Nothing to save: mark the start with I and the end with O", true)
      return
    }
    if (end - start > saveLimit) {
      saveSaid("A saved clip is at most " + saveLimit / 60 + " minutes; "
               + Math.round((end - start) / 60) + " are marked", true)
      return
    }
    var what = camera.name + " " + clockText(start, false) + " (" + Math.round(end - start) + " s)"
    var from = markIn, to = markOut
    saving = true
    saveNoteTimer.stop()
    saveNote = "Saving " + what + "…"
    saveFailed = false
    ask({ op: "save", uid: camera.uid, start: start, end: end, quality: focusQuality }, function(reply) {
      shell.saving = false
      if (reply.ok) {
        var home = Quickshell.env("HOME") || ""
        var path = String(reply.path || "")
        if (home !== "" && path.indexOf(home + "/") === 0) path = "~" + path.slice(home.length)
        shell.saveSaid("Saved " + what + " to " + path, false)
        // Not marks made since, for the next clip.
        if (shell.markIn === from && shell.markOut === to) shell.clearMarks()
      } else {
        shell.saveSaid("Could not save " + what + ": "
                       + (reply.noFootage ? "no recording there" : (reply.error || "something went wrong")), true)
      }
    })
  }

  Timer {
    id: saveNoteTimer
    interval: 15000
    onTriggered: shell.saveNote = ""
  }

  // ---- the helper, for stills, clips and the lanes ----
  property bool backendReady: false
  property var pendingReplies: ({})
  property int nextRequest: 1

  function ask(request, callback) {
    if (!backendReady) return
    request.id = nextRequest++
    pendingReplies[request.id] = callback
    backend.write(JSON.stringify(request) + "\n")
  }

  function backendReply(line) {
    try {
      var reply = JSON.parse(line)
      var callback = pendingReplies[reply.id]
      delete pendingReplies[reply.id]
      if (callback) callback(reply)
    } catch (error) {
      // A tile that asked is gone (another page), or the line was not ours.
    }
  }

  function loadIndex() {
    var uids = []
    for (var i = 0; i < cameras.length; i++) uids.push(cameras[i].uid)
    ask({ op: "index", uids: uids }, function(reply) {
      if (!reply.ok) return
      shell.index = reply.cameras || {}
      shell.indexLoaded = true
    })
  }

  Process {
    id: backend
    command: [shell.cli, "timeline-serve"]
    running: shell.timeline && shell.cli !== ""
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { shell.backendReply(line) } }
    onStarted: {
      shell.backendStarted = Date.now()
      shell.backendReady = true
      backendSettled.restart()
      shell.loadIndex()
    }
    onExited: {
      shell.backendReady = false
      backendSettled.stop()
      shell.pendingReplies = ({})
      if (shell.saving) {
        shell.saving = false
        shell.saveSaid("Could not save: the recordings helper stopped", true)
      }
      // One that stops as soon as it starts is tried less and less often,
      // and the strip says so.
      shell.backendFailures = Date.now() - shell.backendStarted < 10000 ? shell.backendFailures + 1 : 0
      backendRestart.interval = Math.min(60000, 3000 * Math.pow(2, Math.min(5, shell.backendFailures)))
      if (shell.timeline) backendRestart.restart()
    }
  }

  property real backendStarted: 0
  property int backendFailures: 0

  Timer {
    id: backendRestart
    interval: 3000
    onTriggered: backend.running = true
  }

  // One that has stayed up is no longer one that keeps stopping.
  Timer {
    id: backendSettled
    interval: 10000
    onTriggered: shell.backendFailures = 0
  }

  // New detections for the lanes.
  Timer {
    interval: 60000
    repeat: true
    running: shell.timeline && shell.backendReady
    onTriggered: shell.loadIndex()
  }

  Timer {
    interval: 1000
    repeat: true
    running: shell.timeline
    onTriggered: {
      shell.now = Date.now() / 1000
      // A view held on a stretch of the past moves with the 24 hours.
      if (shell.viewEnd > 0 && shell.viewEnd < shell.now - shell.reach + shell.span)
        shell.setViewEnd(shell.viewEnd)
    }
  }

  // The clock recordings play by.
  Timer {
    interval: 200
    repeat: true
    running: shell.reviewing && !shell.paused && !shell.scrubbing
    onTriggered: {
      var time = shell.anchorPlayhead + (Date.now() - shell.anchorWall) / 1000
      if (time > Date.now() / 1000 - shell.liveEdge + 3) { shell.goLive(); return }
      var before = shell.playhead
      shell.playhead = time
      // Played off the right-hand end of the stretch shown: turn the page.
      // Only as it crosses: a view moved elsewhere on purpose stays there.
      if (shell.viewEnd > 0 && before <= shell.viewEndTime && time > shell.viewEndTime)
        shell.setViewEnd(time + shell.span * 0.8)
    }
  }

  // Arrow keys step the playhead; tiles fetch stills until the keys rest.
  Timer {
    id: settleTimer
    interval: 150
    onTriggered: shell.settle()
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
        shell.timeline = data.timeline === true
        shell.playbackQuality = data.playbackQuality || "low"
        shell.consoleNames = data.consoles || {}
        shell.cameras = data.cameras || []
        if (shell.timeline && typeof data.at === "number") shell.seekTo(data.at, true)
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

  // A player and its picture. A Playback has two, so that the next clip
  // can be made ready out of sight and take over without a gap.
  component Deck: Item {
    id: deck
    property bool playAudio: false
    // { path, start, end, chunk, seek, quality }: what the player holds,
    // and the move of the playhead it was fetched for.
    property var clip: null
    // Loaded, and told where in the clip to be.
    property bool positioned: false
    // Where that was (ms), and whether a frame from there has arrived.
    property real target: 0
    property bool hasFrame: false
    property alias player: deckPlayer
    signal placed()
    signal failed(string message)

    function load(newClip) {
      positioned = false
      hasFrame = false
      target = 0
      clip = newClip
      // The same file again would not load anew, and so never be lined up.
      if (String(deckPlayer.source) === "file://" + newClip.path) {
        deckPlayer.stop()
        deckPlayer.source = ""
      }
      deckPlayer.source = "file://" + newClip.path
    }

    function release() {
      clip = null
      positioned = false
      hasFrame = false
      deckPlayer.stop()
      deckPlayer.source = ""
    }

    // Where the shell's clock says this clip should be (ms); its start
    // for a clip made ready ahead of its minute.
    function wanted() {
      return clip === null ? 0 : Math.max(0, (shell.playhead - clip.start) * 1000)
    }

    // Move there. The picture counts as arrived again only once a frame
    // from there has.
    function place(position) {
      target = Math.max(0, Math.min(deckPlayer.duration - 50, position))
      hasFrame = false
      deckPlayer.setPosition(target)
    }

    VideoOutput {
      id: deckVideo
      anchors.fill: parent
      fillMode: VideoOutput.PreserveAspectFit
    }

    Connections {
      target: deckVideo.videoSink
      function onVideoFrameChanged() {
        if (deck.clip !== null && deck.positioned && !deck.hasFrame
            && Math.abs(deckPlayer.position - deck.target) < 2000)
          deck.hasFrame = true
      }
    }

    AudioOutput {
      id: deckAudio
      device: shell.mediaDevices.defaultAudioOutput
      muted: shell.muted
    }

    MediaPlayer {
      id: deckPlayer
      videoOutput: deckVideo
      audioOutput: deck.playAudio ? deckAudio : null
      activeAudioTrack: deck.playAudio ? 0 : -1
      onErrorOccurred: function(error, errorString) {
        if (deck.clip !== null) deck.failed(errorString || "cannot play the recording")
      }
      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.InvalidMedia && deck.clip !== null) {
          deck.failed("cannot play the recording")
          return
        }
        if (deck.clip === null || deck.positioned) return
        if (mediaStatus !== MediaPlayer.LoadedMedia && mediaStatus !== MediaPlayer.BufferedMedia) return
        deck.positioned = true
        var want = deck.wanted()
        if (want > 300) deck.place(want)
        deck.placed()
      }
    }
  }

  // A camera's recording at the shell's playhead: stills while it is
  // dragged, then the clip around it.
  component Playback: Item {
    id: playback
    property string uid: ""
    property string quality: "low"
    // A quality that arrives sooner, shown first while `quality` is on its
    // way (a minute of 4K takes seconds to come). "" for none.
    property string quickQuality: ""
    // Names this view's stills apart from another view of the same camera.
    property string slot: "grid"
    property bool playAudio: false
    // Only views on screen fetch anything.
    property bool active: true
    readonly property var info: shell.index[uid] || null
    readonly property bool needsLogin: !!(info && info.needsLogin)
    property string stillPath: ""
    // Where the still on screen was taken, and where one was last asked for.
    property real stillAt: -1
    property real stillAsked: -1
    property bool stillBusy: false
    // Two decks. `front` holds the clip the clock is in; the other is
    // where the next one is made ready. `shown` is the one on screen: the
    // old front, until the new one has a frame to show.
    property Item front: deckA
    property Item shown: deckA
    readonly property Item back: front === deckA ? deckB : deckA
    property real askedChunk: -1
    property real failedChunk: -1
    property real fetchedAhead: -1
    property real upgradeChunk: -1
    property real refetchedAt: 0
    property int serial: 0
    // Counts the camera changes and stops: an answer from before one is
    // not for what is shown now.
    property int epoch: 0
    // "", "nofootage", or what went wrong.
    property string problem: ""

    // A clip is worth showing in the minute it is for. After a jump an
    // older one is not; when a minute simply runs into the next, the old
    // clip's last frame stays up until the new one takes over.
    function usable(clip) {
      return clip !== null && (clip.chunk === shell.chunkStart
                               || (clip.seek === shell.seekSerial
                                   && clip.chunk === shell.chunkStart - shell.chunkSeconds))
    }
    readonly property bool clipUsable: usable(front.clip)
    readonly property bool videoShowing: shown.hasFrame && usable(shown.clip)
    // A still is worth showing only close to where it was taken.
    readonly property bool stillFresh: stillPath !== "" && Math.abs(stillAt - shell.playhead) < 4

    function refresh() {
      if (!active || uid === "" || !shell.reviewing || !shell.backendReady || needsLogin) return
      // A clip still loading out of sight was told to play when it has.
      if ((shell.scrubbing || shell.paused) && back.clip !== null) back.player.pause()
      if (shell.scrubbing) {
        front.player.pause()
        wantStill()
      } else {
        // A jump elsewhere: stop what was playing, and show a frame from
        // there until the clip comes (unless there is none to come).
        if (!clipUsable) {
          if (front.clip !== null) front.player.pause()
          if (failedChunk !== shell.chunkStart) {
            // What went wrong in the minute left behind says nothing of this one.
            problem = ""
            wantStill()
          }
        }
        wantClip(false)
        fetchAhead()
      }
    }

    function dropClips() {
      deckA.release()
      deckB.release()
      front = deckA
      shown = deckA
    }

    // Another camera in this view (the enlarged one flips): start afresh.
    property bool ready: false
    function reset() {
      if (!ready) return
      serial++
      epoch++
      stillSerial++
      stillBusy = false
      dropClips()
      askedChunk = -1
      failedChunk = -1
      fetchedAhead = -1
      upgradeChunk = -1
      stillPath = ""
      stillAt = -1
      stillAsked = -1
      refetchedAt = 0
      problem = ""
      refresh()
    }
    onUidChanged: reset()
    onQualityChanged: reset()
    onQuickQualityChanged: reset()
    property int stillSerial: 0

    // One request at a time: the next asks for wherever the playhead is by
    // then, so a slow console is never asked for frames already passed.
    function wantStill() {
      if (stillBusy) return
      var at = shell.playhead
      if (stillAsked >= 0 && Math.abs(at - stillAsked) < 0.5) return
      stillAsked = at
      stillBusy = true
      var mine = stillSerial
      shell.ask({ op: "still", uid: uid, at: at, quality: "low", slot: slot }, function(reply) {
        if (mine !== playback.stillSerial) return     // for the camera shown before
        playback.stillBusy = false
        if (reply.ok) {
          playback.stillPath = reply.path
          playback.stillAt = at
          // Not over a clip's own failure, which came after the drag.
          if (shell.scrubbing) playback.problem = ""
        } else {
          // No picture from here: the one from elsewhere must not stand in.
          playback.stillPath = ""
          playback.stillAt = -1
          if (shell.scrubbing)
            playback.problem = reply.noFootage ? "nofootage" : (reply.error || "no picture")
        }
        if (shell.scrubbing && playback.active) playback.wantStill()
      })
    }

    // Into the deck out of sight; it takes over once it is loaded (see
    // deckPlaced), or when its minute comes.
    function loadClip(clip) {
      var deck = back
      // Still waiting for the front's first frame: no longer.
      if (shown === deck) shown = front
      // The next minute's clip was ready there: it is asked for again.
      if (deck.clip !== null && deck.clip.chunk > shell.chunkStart) fetchedAhead = -1
      deck.load(clip)
      if (shell.paused || shell.scrubbing || clip.chunk !== shell.chunkStart) deck.player.pause()
      else deck.player.play()
    }

    function deckPlaced(deck) {
      if (deck === back && deck.clip !== null && deck.clip.chunk === shell.chunkStart) promote()
    }

    // The deck made ready takes over. The one on screen holds its last
    // frame until the new one has a frame of its own.
    function promote() {
      var old = front
      front = back
      if (!shell.paused && !shell.scrubbing) front.player.play()
      else front.player.pause()
      if (old.clip !== null) old.player.pause()
      // What went wrong with the clip before says nothing of this one.
      problem = ""
      showFront()
    }

    function showFront() {
      if (shown === front) return
      // Nothing worth holding on screen, or the new picture is there.
      if (front.hasFrame || !usable(shown.clip)) {
        var old = shown
        shown = front
        old.release()
      }
    }

    function deckFailed(deck, message) {
      // A clip made ready ahead that will not play is tried again when
      // its minute comes; only the one wanted now is a problem to show.
      // Nor is a full-quality clip that fails while the quick one plays.
      var playing = deck !== front && front.clip !== null && front.clip.chunk === shell.chunkStart
      if (deck === front || (deck.clip !== null && deck.clip.chunk === shell.chunkStart && !playing))
        problem = message
      if (deck !== front) {
        if (shown === deck) shown = front
        deck.release()
      }
    }

    // again: fetch this minute's clip anew although one is held (it was
    // cut short at "now", and there is more by now).
    function wantClip(again) {
      var chunk = shell.chunkStart
      if (!again) {
        if (front.clip !== null && front.clip.chunk === chunk) {
          resync()
          wantUpgrade()
          return
        }
        if (back.clip !== null && back.clip.chunk === chunk) {
          // Made ready ahead: its minute has come. (One still loading
          // takes over when it has.)
          if (back.positioned) {
            promote()
            resync()
            wantUpgrade()
          }
          return
        }
      }
      if (askedChunk === chunk || failedChunk === chunk) return
      var end = Math.min(chunk + shell.chunkSeconds, Math.floor(Date.now() / 1000) - shell.recordLag)
      if (end - chunk < 2) return
      askedChunk = chunk
      var mine = ++serial
      // What is on screen keeps its quality; a first clip comes quickly.
      var asked = again ? front.clip.quality : (quickQuality !== "" ? quickQuality : quality)
      // seekSerial lets the helper skip this export if the playhead has
      // moved on by the time its turn comes.
      shell.ask({ op: "clip", uid: uid, start: chunk, end: end, quality: asked,
                  serial: shell.seekSerial }, function(reply) {
        if (mine !== playback.serial) return
        playback.askedChunk = -1
        if (reply.superseded) {
          // Skipped for a later move that stayed within this clip: ask again.
          playback.refresh()
          return
        }
        if (reply.busy) {
          // More being fetched at once than the helper holds: in a moment.
          retryTimer.restart()
          return
        }
        if (!reply.ok) {
          playback.failedChunk = chunk
          playback.dropClips()
          playback.problem = reply.noFootage ? "nofootage" : (reply.error || "no recording")
          return
        }
        playback.problem = ""
        playback.failedChunk = -1
        // Made ready ahead meanwhile: that one will do.
        if (!again && ((playback.front.clip !== null && playback.front.clip.chunk === chunk)
                       || (playback.back.clip !== null && playback.back.clip.chunk === chunk))) return
        playback.loadClip({ path: reply.path, start: reply.start, end: reply.end, chunk: chunk,
                            seek: shell.seekSerial, quality: asked })
        playback.wantUpgrade()
      })
    }

    // The quick clip is up (or on its way): now the one in full quality,
    // which takes over when it lands.
    function wantUpgrade() {
      var chunk = shell.chunkStart
      if (quickQuality === "" || quickQuality === quality || upgradeChunk === chunk) return
      var held = front.clip !== null && front.clip.chunk === chunk ? front.clip
               : back.clip !== null && back.clip.chunk === chunk ? back.clip : null
      if (held === null || held.quality === quality) return
      upgradeChunk = chunk
      var mine = epoch
      shell.ask({ op: "clip", uid: uid, start: chunk, end: held.end, quality: quality,
                  serial: shell.seekSerial }, function(reply) {
        if (mine !== playback.epoch || !playback.active) return
        if (reply.superseded) {
          playback.upgradeChunk = -1
          playback.refresh()
          return
        }
        if (reply.busy || chunk !== shell.chunkStart) {
          // Not this time: asked again when the playhead is in that minute.
          if (playback.upgradeChunk === chunk) playback.upgradeChunk = -1
          if (reply.busy) retryTimer.restart()
          return
        }
        // Without it the quick clip stays; this minute is not asked again.
        if (!reply.ok) return
        playback.loadClip({ path: reply.path, start: reply.start, end: reply.end, chunk: chunk,
                            seek: shell.seekSerial, quality: playback.quality })
      })
    }

    // Back in step with the shell's clock, after a move within the clip
    // or a stall.
    function resync() {
      var clip = front.clip
      var player = front.player
      if (clip === null || !front.positioned) return
      var want = (shell.playhead - clip.start) * 1000
      if (want > player.duration - 3000 && clip.end < clip.chunk + shell.chunkSeconds - 1) {
        // A clip cut short at "now" is about to run out: there is more by
        // now, and it takes over when it comes. A console that sends less
        // than asked is not asked again and again.
        if (Date.now() - refetchedAt > 4000) {
          refetchedAt = Date.now()
          wantClip(true)
        }
        if (want > player.duration + 500) return
      }
      if (Math.abs(player.position - want) > 1500) front.place(want)
      if (shell.paused) player.pause()
      else if (player.playbackState !== MediaPlayer.PlayingState && want < player.duration - 200) player.play()
    }

    // The next clip, fetched and made ready before this one ends. Close
    // behind "now" the next minute is not all recorded yet: then what
    // there is of it, in the last seconds.
    function fetchAhead() {
      var next = shell.chunkStart + shell.chunkSeconds
      if (shell.paused || fetchedAhead === next) return
      var left = next - shell.playhead
      if (left > 20) return
      var recorded = Math.floor(Date.now() / 1000) - shell.recordLag
      var end = next + shell.chunkSeconds
      if (end > recorded) {
        if (left > 3 || recorded - next < 2) return
        end = recorded
      }
      fetchedAhead = next
      var mine = epoch
      shell.ask({ op: "clip", uid: uid, start: next, end: end, quality: quality,
                  serial: shell.seekSerial }, function(reply) {
        if (mine !== playback.epoch || !playback.active || !reply.ok) return
        // Only for the minute coming up, or just begun, and only if
        // nothing has it already or is using the deck out of sight.
        if (next !== shell.chunkStart && next !== shell.chunkStart + shell.chunkSeconds) return
        var front = playback.front.clip
        var back = playback.back.clip
        if (front !== null && front.chunk === next) return
        if (back !== null && back.chunk >= shell.chunkStart) {
          // The deck is busy with this minute: asked again in a moment
          // (the helper has the clip by now).
          if (back.chunk !== next) playback.fetchedAhead = -1
          return
        }
        playback.loadClip({ path: reply.path, start: reply.start, end: reply.end, chunk: next,
                            seek: shell.seekSerial, quality: playback.quality })
      })
    }

    Timer {
      id: retryTimer
      interval: 2000
      onTriggered: playback.refresh()
    }

    onActiveChanged: {
      if (active) { refresh(); return }
      serial++
      epoch++
      askedChunk = -1
      upgradeChunk = -1
      fetchedAhead = -1
      dropClips()
    }
    onNeedsLoginChanged: refresh()
    Component.onCompleted: {
      ready = true
      refresh()
    }

    Connections {
      target: shell
      function onPlayheadChanged() { if (shell.scrubbing) playback.refresh() }
      function onScrubbingChanged() { playback.refresh() }
      function onSeekSerialChanged() { playback.failedChunk = -1; playback.refresh() }
      function onChunkStartChanged() { if (!shell.scrubbing) playback.refresh() }
      function onPausedChanged() { playback.refresh() }
      function onBackendReadyChanged() {
        // A restarted helper answers nothing it was asked before, and what
        // failed as it went down may work now.
        playback.stillBusy = false
        playback.askedChunk = -1
        playback.failedChunk = -1
        playback.upgradeChunk = -1
        playback.fetchedAhead = -1
        playback.refresh()
      }
      function onNowChanged() { if (!shell.scrubbing) playback.refresh() }
    }

    Deck {
      id: deckA
      anchors.fill: parent
      playAudio: playback.playAudio
      visible: playback.shown === deckA && playback.usable(clip)
      onPlaced: playback.deckPlaced(deckA)
      onHasFrameChanged: playback.showFront()
      onFailed: function(message) { playback.deckFailed(deckA, message) }
    }

    Deck {
      id: deckB
      anchors.fill: parent
      playAudio: playback.playAudio
      visible: playback.shown === deckB && playback.usable(clip)
      onPlaced: playback.deckPlaced(deckB)
      onHasFrameChanged: playback.showFront()
      onFailed: function(message) { playback.deckFailed(deckB, message) }
    }

    // The frame under the playhead, until the clip from there plays.
    Image {
      anchors.fill: parent
      // While dragging, the latest frame there is; afterwards only one
      // from about where the playhead is, never an old one flashing back.
      visible: playback.stillPath !== "" && playback.problem === ""
               && (shell.scrubbing || (playback.stillFresh && !playback.videoShowing))
      source: playback.stillPath !== "" ? "file://" + playback.stillPath : ""
      fillMode: Image.PreserveAspectFit
      cache: false
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      width: parent.width - 24
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      visible: text !== ""
      text: playback.needsLogin
            ? "Sign in to see recordings\neld-unifi-protect login " + (playback.info.console || "")
            : playback.problem === "nofootage" ? "No recording at " + shell.clockText(shell.playhead, false)
            : playback.problem !== "" ? playback.problem
            : !playback.usable(playback.shown.clip) && !playback.stillFresh ? "Loading…" : ""
      color: playback.problem !== "" && playback.problem !== "nofootage" ? "#ff7777" : "#cccccc"
      font.pixelSize: 16
    }
  }

  // ---- the timeline strip ----
  //
  // A lane per camera shown: footage as a solid band, hatched where there
  // is none, detections as coloured marks. Click or drag to move the
  // playhead; the wheel zooms around the pointer, Shift+wheel pans.
  component TimelineStrip: Rectangle {
    id: timelineStrip
    color: "#101112"
    readonly property var lanes: shell.laneCameras
    // The strip is one height whatever it shows: the grid above must not
    // change shape (and so its page of cameras) with the number of lanes.
    readonly property real lanesArea: 150
    // Every lane fits, however many cameras the page holds (36 at most);
    // thin lanes lose their gap and then their name.
    readonly property real lanePitch: Math.floor(lanesArea / Math.max(1, lanes.length))
    readonly property real laneGap: lanePitch >= 8 ? 2 : 1
    readonly property real laneHeight: Math.max(2, Math.min(32, lanePitch - laneGap))
    readonly property real gutter: 200
    readonly property real trackX: gutter
    readonly property real trackWidth: Math.max(100, width - gutter - 16)
    readonly property real lanesHeight: lanes.length * (laneHeight + laneGap)
    readonly property real playheadTime: shell.reviewing ? shell.playhead : shell.now
    implicitHeight: 44 + lanesArea + 24 + 26

    function timeAt(x) { return shell.viewStart + x / trackWidth * shell.span }
    function xAt(time) { return (time - shell.viewStart) / shell.span * trackWidth }

    // ---- where we are ----
    Text {
      id: clock
      textFormat: Text.PlainText
      x: 16
      y: 8
      text: shell.reviewing ? shell.clockText(shell.playhead, true) : "LIVE"
      color: shell.reviewing ? "white" : "#ff5555"
      font.pixelSize: 22
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: clock.right
      anchors.leftMargin: 14
      anchors.baseline: clock.baseline
      text: (shell.paused ? "paused  ·  " : shell.scrubbing ? "" : shell.reviewing ? "recorded  ·  " : "")
            + shell.spanText(shell.span) + " shown"
            + (shell.markIn >= 0 && shell.markOut >= 0
               ? "  ·  marked " + shell.clockText(shell.markIn, false) + "–" + shell.clockText(shell.markOut, false)
                 + " (" + Math.round(shell.markOut - shell.markIn) + " s): "
                 + (shell.markOut - shell.markIn > shell.saveLimit
                    ? "more than the " + shell.saveLimit / 60 + " minutes S can save" : "S saves it")
                 + (shell.saveCamera ? " for " + shell.saveCamera.name : "") + ", X clears"
               : shell.markIn >= 0 ? "  ·  start marked at " + shell.clockText(shell.markIn, false) + ": O marks the end"
               : shell.markOut >= 0 ? "  ·  end marked at " + shell.clockText(shell.markOut, false) + ": I marks the start"
               : "")
            + (shell.backendFailures >= 3 ? "  ·  the recordings helper keeps stopping; "
                                            + "run `eld-unifi-protect timeline-serve` to see why"
               : shell.indexLoaded ? "" : "  ·  loading detections…")
      color: shell.backendFailures >= 3 ? "#ff7777" : "#9aa0a6"
      font.pixelSize: 14
      anchors.right: saveButtons.visible ? saveButtons.left : legend.visible ? legend.left : liveButton.left
      anchors.rightMargin: 14
      elide: Text.ElideRight
    }

    // ---- saving what is marked ----
    Row {
      id: saveButtons
      readonly property real marked: shell.markOut - shell.markIn
      readonly property bool tooLong: marked > shell.saveLimit
      visible: shell.markIn >= 0 && shell.markOut >= 0
      anchors.right: liveButton.left
      anchors.rightMargin: 12
      anchors.verticalCenter: liveButton.verticalCenter
      spacing: 6
      Rectangle {
        readonly property bool usable: !shell.saving && !saveButtons.tooLong && !!shell.saveCamera && shell.backendReady
        width: saveLabel.implicitWidth + 24
        height: 28
        radius: 14
        color: !usable ? "#26282a" : saveArea.containsMouse ? "#ffe08a" : "#ffd24a"
        Text {
          id: saveLabel
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: shell.saving ? "Saving…"
                : saveButtons.tooLong ? "Too long to save"
                : "Save clip (" + (saveButtons.marked >= 120 ? Math.round(saveButtons.marked / 6) / 10 + " min"
                                                             : Math.round(saveButtons.marked) + " s") + ")"
          color: parent.usable ? "#1b1c1d" : "#9aa0a6"
          font.pixelSize: 14
          font.bold: true
        }
        MouseArea {
          id: saveArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: parent.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: if (parent.usable) shell.saveClip()
        }
      }
      Rectangle {
        width: 28
        height: 28
        radius: 14
        color: clearArea.containsMouse ? "#3a3d40" : "#26282a"
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "✕"
          color: "white"
          font.pixelSize: 13
        }
        MouseArea {
          id: clearArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: shell.clearMarks()
        }
      }
    }

    Row {
      id: legend
      // Room for it only in a wide window, and not beside the save button.
      visible: timelineStrip.width >= 1200 && !saveButtons.visible
      anchors.right: liveButton.left
      anchors.rightMargin: 18
      anchors.verticalCenter: liveButton.verticalCenter
      spacing: 14
      Repeater {
        model: [["person", "Person"], ["vehicle", "Vehicle"], ["animal", "Animal"],
                ["package", "Package"], ["ring", "Doorbell"], ["motion", "Motion"]]
        Row {
          required property var modelData
          spacing: 5
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 10; height: 10; radius: 2
            color: shell.kindColors[modelData[0]]
          }
          Text {
            textFormat: Text.PlainText
            text: modelData[1]
            color: "#9aa0a6"
            font.pixelSize: 12
          }
        }
      }
    }

    Rectangle {
      id: liveButton
      anchors.right: parent.right
      anchors.rightMargin: 16
      y: 8
      width: liveLabel.implicitWidth + 24
      height: 28
      radius: 14
      color: shell.reviewing ? (liveArea.containsMouse ? "#3a3d40" : "#26282a") : "#5a1f1f"
      Text {
        id: liveLabel
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: shell.reviewing ? "Go live" : "● Live"
        color: "white"
        font.pixelSize: 14
        font.bold: true
      }
      MouseArea {
        id: liveArea
        anchors.fill: parent
        hoverEnabled: true
        onClicked: shell.goLive()
      }
    }

    // ---- lanes ----
    Column {
      id: laneColumn
      x: 0
      y: 44
      width: parent.width
      spacing: timelineStrip.laneGap

      Repeater {
        model: timelineStrip.lanes

        Item {
          id: lane
          required property var modelData
          required property int index
          readonly property var info: shell.index[modelData.uid] || null
          readonly property bool selected: shell.focusedIndex < 0
                                           && shell.pageStart + index === shell.selectedIndex
          width: laneColumn.width
          height: timelineStrip.laneHeight

          Text {
            textFormat: Text.PlainText
            x: 16
            width: timelineStrip.gutter - 28
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            visible: timelineStrip.laneHeight >= 9
            text: lane.modelData.name
            color: lane.selected ? "white" : "#9aa0a6"
            font.pixelSize: Math.max(9, Math.min(13, timelineStrip.laneHeight - 3))
            font.bold: lane.selected
          }

          Canvas {
            id: band
            x: timelineStrip.trackX
            width: timelineStrip.trackWidth
            height: parent.height

            readonly property var info: lane.info
            readonly property real viewStart: shell.viewStart
            readonly property real span: shell.span
            onInfoChanged: requestPaint()
            onViewStartChanged: requestPaint()
            onSpanChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              var w = width, h = height
              var start = shell.viewStart, span = shell.span, now = shell.now
              function x(time) { return (time - start) / span * w }
              ctx.clearRect(0, 0, w, h)
              // No footage, until shown otherwise: dark, hatched.
              ctx.fillStyle = "#17181a"
              ctx.fillRect(0, 0, w, h)
              ctx.strokeStyle = "#2b2d30"
              ctx.lineWidth = 1
              ctx.beginPath()
              for (var d = -h; d < w; d += 7) {
                ctx.moveTo(d, h)
                ctx.lineTo(d + h, 0)
              }
              ctx.stroke()
              if (!info || info.needsLogin || info.error) return
              var events = info.events || []
              var edge = Math.min(w, x(now))
              var pad = 10
              ctx.fillStyle = "#2c4152"
              if (info.coverage === "always") {
                var from = Math.max(0, x(info.from || 0))
                if (edge > from) ctx.fillRect(from, 0, edge - from, h)
              } else if (info.coverage === "unknown") {
                // A schedule, say: there may be footage anywhere.
                ctx.fillStyle = "#22292f"
                ctx.fillRect(0, 0, edge, h)
              } else if (info.coverage === "events") {
                for (var i = 0; i < events.length; i++) {
                  var a = x(events[i].start - pad), b = x((events[i].end || now) + pad)
                  if (b < 0 || a > w) continue
                  ctx.fillRect(a, 0, Math.max(1.5, b - a), h)
                }
              }
              // Motion first, so detections draw over it.
              for (var pass = 0; pass < 2; pass++) {
                for (var j = events.length - 1; j >= 0; j--) {
                  var event = events[j]
                  if ((event.kind === "motion") !== (pass === 0)) continue
                  var left = x(event.start), right = x(event.end || now)
                  if (right < 0 || left > w) continue
                  ctx.fillStyle = shell.kindColors[event.kind] || shell.kindColors.motion
                  if (pass === 0) ctx.fillRect(left, h * 0.55, Math.max(1.5, right - left), h * 0.45)
                  else ctx.fillRect(left, 0, Math.max(2.5, right - left), h)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            x: timelineStrip.trackX + 8
            anchors.verticalCenter: parent.verticalCenter
            visible: !!(lane.info && (lane.info.needsLogin || lane.info.error))
                     && timelineStrip.laneHeight >= 9
            text: !lane.info ? ""
                  : lane.info.needsLogin
                    ? "Sign in to see recordings: eld-unifi-protect login " + (lane.info.console || "")
                    : (lane.info.error || "")
            color: lane.info && lane.info.error ? "#ff7777" : "#9aa0a6"
            font.pixelSize: Math.max(9, Math.min(12, timelineStrip.laneHeight - 3))
          }
        }
      }
    }

    // ---- hours ----
    Canvas {
      id: axis
      x: timelineStrip.trackX
      y: laneColumn.y + timelineStrip.lanesHeight
      width: timelineStrip.trackWidth
      height: 24
      readonly property real viewStart: shell.viewStart
      readonly property real span: shell.span
      onViewStartChanged: requestPaint()
      onSpanChanged: requestPaint()
      onWidthChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        var steps = [60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600]
        var step = steps[steps.length - 1]
        for (var i = 0; i < steps.length; i++)
          if (shell.span / steps[i] <= width / 90) { step = steps[i]; break }
        // Marks on the local hour, whatever the time zone's offset.
        var offset = new Date(shell.viewStart * 1000).getTimezoneOffset() * 60
        var first = Math.ceil((shell.viewStart - offset) / step) * step + offset
        ctx.fillStyle = "#9aa0a6"
        ctx.strokeStyle = "#4a4d50"
        ctx.font = "12px sans-serif"
        ctx.textAlign = "center"
        ctx.beginPath()
        for (var time = first; time <= shell.viewEndTime; time += step) {
          var x = (time - shell.viewStart) / shell.span * width
          ctx.moveTo(x, 0)
          ctx.lineTo(x, 5)
          if (x > 18 && x < width - 18)
            ctx.fillText(Qt.formatDateTime(new Date(time * 1000), "HH:mm"), x, 18)
        }
        ctx.stroke()
      }
    }

    // ---- the stretch marked for saving ----
    Rectangle {
      readonly property real from: timelineStrip.xAt(shell.markIn >= 0 ? shell.markIn : shell.markOut)
      readonly property real to: timelineStrip.xAt(shell.markOut >= 0 ? shell.markOut : shell.markIn)
      readonly property real fromX: Math.max(0, Math.min(timelineStrip.trackWidth, from))
      readonly property real toX: Math.max(0, Math.min(timelineStrip.trackWidth, to))
      visible: shell.markIn >= 0 && shell.markOut >= 0 && toX > fromX
      x: timelineStrip.trackX + fromX
      y: laneColumn.y - 2
      width: toX - fromX
      height: timelineStrip.lanesHeight + 4
      // Red while it is longer than can be saved.
      color: shell.markOut - shell.markIn > shell.saveLimit ? "#40ff5555" : "#40ffd24a"
    }

    Repeater {
      model: [shell.markIn, shell.markOut]
      Rectangle {
        required property real modelData
        readonly property real at: timelineStrip.xAt(modelData)
        visible: modelData >= 0 && at >= 0 && at <= timelineStrip.trackWidth
        x: timelineStrip.trackX + at - 1
        y: laneColumn.y - 4
        width: 2
        height: timelineStrip.lanesHeight + 8
        color: "#ffd24a"
      }
    }

    // ---- the pointer ----
    Rectangle {
      visible: trackArea.containsMouse && !trackArea.pressed
      x: timelineStrip.trackX + trackArea.mouseX
      y: laneColumn.y
      width: 1
      height: timelineStrip.lanesHeight
      color: "#80ffffff"
    }

    Rectangle {
      visible: trackArea.containsMouse && !trackArea.pressed
      x: Math.max(timelineStrip.trackX, Math.min(timelineStrip.trackX + timelineStrip.trackWidth - width,
                                                  timelineStrip.trackX + trackArea.mouseX - width / 2))
      y: laneColumn.y - height - 2
      width: hoverLabel.implicitWidth + 12
      height: hoverLabel.implicitHeight + 4
      radius: 4
      color: "#26282a"
      Text {
        id: hoverLabel
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: shell.clockText(timelineStrip.timeAt(trackArea.mouseX), false)
        color: "white"
        font.pixelSize: 12
      }
    }

    // ---- the playhead ----
    Rectangle {
      readonly property real at: timelineStrip.xAt(timelineStrip.playheadTime)
      visible: at >= -1 && at <= timelineStrip.trackWidth + 1
      x: timelineStrip.trackX + Math.max(0, Math.min(timelineStrip.trackWidth - width, at - width / 2))
      y: laneColumn.y - 4
      width: 2
      height: timelineStrip.lanesHeight + 8
      color: shell.reviewing ? "white" : "#ff5555"
    }

    MouseArea {
      id: trackArea
      x: timelineStrip.trackX
      y: laneColumn.y - 6
      width: timelineStrip.trackWidth
      height: timelineStrip.lanesHeight + 30
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      // A drag marks the stretch it covers, for saving, as well as taking
      // the cameras along; a click only goes there, and so does a drag
      // with Shift held. The marks follow once the pointer has moved far
      // enough not to be a click.
      property real pressedX: 0
      property real pressedTime: 0
      property bool marks: false
      property bool marking: false
      function timeFor(x) { return timelineStrip.timeAt(Math.max(0, Math.min(width, x))) }
      function press(x, plain) {
        pressedX = x
        pressedTime = timeFor(x)
        marks = plain
        marking = false
        shell.seekTo(pressedTime, false)
      }
      function move(x) {
        if (marks && !marking && Math.abs(x - pressedX) >= 6) marking = true
        if (marking) shell.markBetween(pressedTime, timeFor(x))
        shell.seekTo(timeFor(x), false)
      }
      function release(x) {
        if (marking) shell.markBetween(pressedTime, timeFor(x))
        marking = false
        shell.seekTo(timeFor(x), true)
      }
      onPressed: function(mouse) { press(mouse.x, !(mouse.modifiers & Qt.ShiftModifier)) }
      onPositionChanged: function(mouse) { if (pressed) move(mouse.x) }
      onReleased: function(mouse) { release(mouse.x) }
      onCanceled: { marking = false; shell.settle() }
      onWheel: function(wheel) {
        var notches = wheel.angleDelta.y / 120
        if (wheel.modifiers & Qt.ShiftModifier) shell.setViewEnd(shell.viewEndTime - notches * shell.span / 8)
        else shell.setSpan(shell.span * Math.pow(0.8, notches), timelineStrip.timeAt(wheel.x))
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 6
      width: Math.min(implicitWidth, parent.width - 32)
      elide: Text.ElideRight
      text: shell.saveNote !== "" ? shell.saveNote
            : "Click or ←/→ 10 s (Shift 1 min)  ·  , . detections  ·  Space pause  ·  + − or wheel zoom"
            + "  ·  drag or I O mark, S save  ·  End live  ·  Enter enlarge  ·  H/L camera"
            + (shell.focusedIndex >= 0 ? "  ·  M mute" : "  ·  G layout")
            + (shell.focusedIndex < 0 && shell.pageCount > 1
               ? "  ·  PgDn page " + (shell.page + 1) + "/" + shell.pageCount : "")
            + "  ·  Q close"
      color: shell.saveNote === "" ? "#6f757b" : shell.saveFailed ? "#ff7777" : "#d8dde2"
      font.pixelSize: shell.saveNote === "" ? 12 : 13
    }
  }

  // ---- contents, shared by both window modes ----
  component WallView: Item {
    id: keys
    anchors.fill: parent
    focus: true

    Binding { target: shell; property: "viewWidth"; value: stage.width }
    Binding { target: shell; property: "viewHeight"; value: stage.height }

    // The timeline window's own keys; true if the key was one of them.
    // Left and Right move through time there, so H and L (and the mouse)
    // move between cameras.
    function timelineKey(event, text) {
      var shift = event.modifiers & Qt.ShiftModifier
      // A held key repeats only for stepping through time; each of the
      // others would fetch for every tile on every repeat.
      var once = !event.isAutoRepeat
      if (event.key === Qt.Key_Left) shell.stepBy(shift ? -60 : -10)
      else if (event.key === Qt.Key_Right) shell.stepBy(shift ? 60 : 10)
      else if (text === "," || text === "<") { if (once) shell.jumpEvent(-1) }
      else if (text === "." || text === ">") { if (once) shell.jumpEvent(1) }
      else if (text === "+" || text === "=") { if (once) shell.zoomStep(-1) }
      else if (text === "-") { if (once) shell.zoomStep(1) }
      else if (event.key === Qt.Key_Space) { if (once) shell.togglePause() }
      else if (text === "i") { if (once) shell.mark(false) }
      else if (text === "o") { if (once) shell.mark(true) }
      else if (text === "s") { if (once) shell.saveClip() }
      else if (text === "x") { if (once) shell.clearMarks() }
      else if (event.key === Qt.Key_End || event.key === Qt.Key_Backspace) shell.goLive()
      else if (event.key === Qt.Key_Escape && shell.focusedIndex < 0 && shell.reviewing) shell.goLive()
      else return false
      return true
    }

    Keys.onReleased: function(event) {
      if (shell.timeline && !event.isAutoRepeat
          && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) shell.stepReleased()
    }

    Keys.onPressed: function(event) {
      hintTimer.restart()
      var text = event.text.toLowerCase()
      if (shell.timeline && timelineKey(event, text)) {
        event.accepted = true
        return
      }
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

    // The cameras; the timeline window keeps its strip below them.
    Item {
      id: stage
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: shell.timeline ? strip.top : parent.bottom

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

            // Live, or (in the timeline window) the recording at the
            // playhead. Going back to live reconnects the stream.
            Loader {
              anchors.fill: parent
              anchors.margins: tile.border.width
              active: !shell.reviewing
              sourceComponent: Stream {
                url: tile.modelData.grid || ""
                uid: tile.modelData.uid || ""
                quality: shell.gridQuality
                snapshot: shell.snapshotDir ? "file://" + shell.snapshotDir + "/" + tile.modelData.uid + ".jpg" : ""
              }
            }

            Loader {
              anchors.fill: parent
              anchors.margins: tile.border.width
              active: shell.reviewing
              sourceComponent: Playback {
                uid: tile.modelData.uid || ""
                quality: shell.playbackQuality
                slot: "grid"
                active: grid.visible
              }
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
          Loader {
            anchors.fill: parent
            active: !shell.reviewing
            sourceComponent: Stream {
              url: shell.focusedCamera ? shell.focusedCamera.focus || shell.focusedCamera.grid : ""
              uid: shell.focusedCamera ? shell.focusedCamera.uid : ""
              quality: shell.focusedCamera && shell.focusedCamera.focus ? shell.focusQuality : shell.gridQuality
              snapshot: shell.focusedCamera && shell.snapshotDir
                        ? "file://" + shell.snapshotDir + "/" + shell.focusedCamera.uid + ".jpg" : ""
              playAudio: true
            }
          }

          Loader {
            anchors.fill: parent
            active: shell.reviewing
            sourceComponent: Playback {
              uid: shell.focusedCamera ? shell.focusedCamera.uid : ""
              quality: shell.focusQuality
              quickQuality: shell.focusQuality !== "low" ? "low" : ""
              slot: "focus"
              playAudio: true
            }
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
              text: (shell.reviewing ? "REC " + shell.clockText(shell.playhead, false) + "  ·  " : "● ")
                    + (shell.focusedCamera ? shell.focusedCamera.name : "")
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
    }

    Loader {
      id: strip
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      active: shell.timeline
      height: item ? item.implicitHeight : 0
      sourceComponent: TimelineStrip {}
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
      // The timeline window lists its keys in the strip instead.
      visible: !shell.timeline
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
      title: shell.timeline ? "UniFi Protect Timeline" : "UniFi Protect Wall"
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
      WlrLayershell.namespace: shell.timeline ? "eld-unifi-protect-timeline" : "eld-unifi-protect-wall"
      color: "black"

      WallView { anchors.fill: parent }
    }
  }
}
