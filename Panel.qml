import QtQuick
import QtQuick.Controls
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// UniFi Protect popup.
//
// Three views share the card: a grid of camera snapshots, a live view of
// one camera, and that camera's recorded detections. The panel never speaks HTTP. `eld-unifi-protect` polls the
// console, writes state and snapshots to disk, and resolves stream URLs; the
// panel watches those files and plays the RTSPS stream with QtMultimedia.
//
// Snapshots only refresh while the panel is open, and live video only plays
// while it is shown: a closed panel costs the console one camera-list poll a
// minute, for the bar's health colour.
Panel {
  id: root
  moduleName: "com.eldtechnologies.unifi-protect"
  manageIpc: false

  property Item anchorItem: null
  property var hostWidget: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state")
  readonly property string statePath: stateHome + "/eld-unifi-protect/state.json"
  // No shared fallback such as /tmp: the helper refuses to run without the
  // private runtime directory, so there would be nothing to read there.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
                                       ? Quickshell.env("XDG_RUNTIME_DIR") + "/eld-unifi-protect" : ""
  readonly property string snapDir: runtimeDir + "/snapshots"
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace("file://", ""))
  readonly property string cli: pluginDir + "bin/eld-unifi-protect"

  // Version and release notes come from manifest.json, the one place the
  // version is set, so the panel can never disagree with the plugin.
  property string pluginVersion: ""
  property string homepage: ""
  readonly property string releaseUrl: homepage !== "" && pluginVersion !== ""
                                       ? homepage + "/releases/tag/v" + pluginVersion : ""

  FileView {
    path: root.pluginDir + "manifest.json"
    printErrors: false
    onLoaded: {
      try {
        var manifest = JSON.parse(text())
        root.pluginVersion = manifest.version || ""
        root.homepage = String(manifest.homepage || "").replace(/\/+$/, "")
      } catch (error) { }
    }
  }

  // Presets for the settings UI. An explicit snapshotIntervalSec in
  // shell.json (the older setting) still wins.
  readonly property int snapshotSeconds: {
    var explicit = Number(setting("snapshotIntervalSec", 0))
    if (explicit > 0) return Math.max(1, explicit)
    var preset = setting("refresh", "balanced")
    return preset === "fast" ? 1 : preset === "efficient" ? 10 : 3
  }
  // fill: crop the picture to the tile; fit: show all of it, letterboxed.
  readonly property bool framingFill: setting("framing", "fill") !== "fit"
  readonly property bool openFavoriteLive: setting("openFavoriteLive", false) === true
  readonly property int columns: Math.max(1, Math.min(4, setting("columns", 2)))
  readonly property string liveQuality: validQuality(setting("liveQuality", "medium"), "medium")
  readonly property string popoutQuality: validQuality(setting("popoutQuality", "high"), "high")
  // Sound whenever a single camera is shown; the grid itself is always silent.
  readonly property bool soundDefault: setting("sound", true) !== false

  property var state: ({})
  property var snapIndex: ({})

  // ---- derived state -------------------------------------------------

  readonly property var allCameras: state && state.cameras ? state.cameras : []
  // Hidden cameras (by hand, or offline with hideOffline on) leave the grid,
  // the keyboard order and the bar's health colour alike; "Show hidden"
  // brings them back to the grid only, so they can be unhidden.
  readonly property bool hideOffline: state && state.hideOffline === true
  property bool showHidden: false
  function isHidden(camera) { return camera.hidden === true || (hideOffline && !camera.online) }
  readonly property var shownCameras: allCameras.filter(function(c) { return !root.isHidden(c) })
  readonly property var cameras: showHidden ? allCameras : shownCameras
  readonly property int hiddenCount: allCameras.length - shownCameras.length
  readonly property var consoles: state && state.consoles ? state.consoles : []
  readonly property bool multiConsole: consoles.length > 1
  readonly property bool configured: state && state.updatedAt !== undefined
                                     && state.configured !== false
  readonly property bool stale: configured && state.stale === true
  readonly property int onlineCount: {
    var count = 0
    for (var i = 0; i < shownCameras.length; i++) if (shownCameras[i].online) count++
    return count
  }
  readonly property bool healthy: configured && onlineCount === shownCameras.length

  // ---- alerts ----
  //
  // The helper's `events` listener writes alerts.json; acknowledging writes
  // alerts-ack.json. Unacknowledged alerts light the bar until the panel
  // is opened; a camera's tile stays marked for ten minutes either way.
  property var alertsData: ({})
  property real ackedAt: 0
  property real clearedAt: 0
  // The alert log: everything since the last Clear, newest first.
  property bool alertsView: false
  property real seenBefore: 0      // alerts newer than this are marked new
  readonly property var logAlerts: alerts.filter(function(a) { return a.start > root.clearedAt })
                                         .slice().reverse()
  property real nowSec: Date.now() / 1000
  readonly property var alerts: alertsData && alertsData.alerts ? alertsData.alerts : []
  readonly property var unackedAlerts: alerts.filter(function(a) { return a.start > root.ackedAt })
  readonly property bool alerting: configured && unackedAlerts.length > 0
  readonly property var latestAlert: unackedAlerts.length ? unackedAlerts[unackedAlerts.length - 1] : null
  readonly property int armedCount: allCameras.filter(function(c) {
    return c.alerts && c.alerts.length > 0 }).length
  readonly property var alertProblems: {
    var out = []
    var statuses = alertsData && alertsData.consoles ? alertsData.consoles : {}
    for (var id in statuses) {
      if (statuses[id] && statuses[id].connected === false && statuses[id].error) {
        var name = id
        for (var i = 0; i < consoles.length; i++) if (consoles[i].id === id) name = consoles[i].name
        out.push(name + ": " + statuses[id].error)
      }
    }
    return out
  }

  function alertLabel(kind) {
    return { person: "Person", vehicle: "Vehicle", animal: "Animal", package: "Package",
             ring: "Doorbell", motion: "Motion", audio: "Sound", face: "Face",
             licensePlate: "Licence plate" }[kind] || kind
  }

  function ago(seconds) {
    var age = root.nowSec - seconds
    if (age < 60) return "just now"
    if (age < 3600) return Math.floor(age / 60) + " min ago"
    return Qt.formatTime(new Date(seconds * 1000), "HH:mm")
  }

  // The newest alert for a camera within the last ten minutes, or null.
  function recentAlert(uid) {
    for (var i = alerts.length - 1; i >= 0; i--) {
      if (alerts[i].uid === uid) return root.nowSec - alerts[i].start < 600 ? alerts[i] : null
    }
    return null
  }

  // Stops a run whose answer is no longer wanted. Its exit still arrives,
  // after anything set up for the next run, so it is counted and skipped.
  function stopProcess(process) {
    if (!process.running) return
    process.stale++
    process.running = false
  }

  // The recording of the alert when signed in to that console, else live.
  function openAlert(alert) {
    for (var i = 0; i < allCameras.length; i++) {
      if (allCameras[i].uid === alert.uid) {
        if (root.consoleHasRecordings(allCameras[i].console)) {
          root.openRecordings(allCameras[i], alert, "alerts")
        } else {
          root.alertsView = false
          root.openLive(allCameras[i])
        }
        return
      }
    }
  }

  function clearAlerts() {
    Quickshell.execDetached([root.cli, "alert", "--clear"])
  }

  function setArmed(camera, armed) {
    Quickshell.execDetached(armed ? [root.cli, "alert", camera.uid]
                                  : [root.cli, "alert", camera.uid, "--off"])
  }

  readonly property string barTooltip: {
    if (!configured) return "UniFi Protect — not set up yet"
    var lines = []
    if (latestAlert) {
      lines.push("● " + alertLabel(latestAlert.kind) + " · " + latestAlert.camera + " · "
                 + Qt.formatTime(new Date(latestAlert.start * 1000), "HH:mm")
                 + (unackedAlerts.length > 1 ? "  (+" + (unackedAlerts.length - 1) + " more)" : ""))
    }
    lines.push(onlineCount + "/" + shownCameras.length + " cameras online"
                 + (hiddenCount ? " · " + hiddenCount + " hidden" : ""))
    for (var c = 0; c < consoles.length; c++)
      if (consoles[c].stale) lines.push("! " + consoles[c].name + " unreachable")
    for (var i = 0; i < shownCameras.length; i++)
      if (!shownCameras[i].online) lines.push("! " + shownCameras[i].name + " offline")
    return lines.join("\n")
  }

  // ---- live view state -----------------------------------------------

  property var liveCamera: null
  property string liveError: ""
  property bool muted: true
  property int selectedIndex: 0

  readonly property bool liveMode: liveCamera !== null
  readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
                                  && player.mediaStatus !== MediaPlayer.LoadingMedia
                                  && player.mediaStatus !== MediaPlayer.StalledMedia

  function validQuality(value, fallback) {
    return ["high", "medium", "low"].indexOf(String(value)) >= 0 ? String(value) : fallback
  }

  function snapshotUrl(cameraId) {
    var stamp = root.snapIndex[cameraId]
    if (!stamp) return ""
    // The query only defeats the pixmap cache; the loader ignores it.
    return "file://" + root.snapDir + "/" + cameraId + ".jpg?t=" + stamp
  }

  function openLive(camera) {
    if (!camera) return
    // Coming from the grid starts at the default; M carries over while
    // flipping between cameras.
    if (!root.liveMode) root.muted = !root.soundDefault
    root.leaveRecordings()
    root.alertsView = false
    root.liveError = ""
    root.liveCamera = camera
    for (var i = 0; i < cameras.length; i++) if (cameras[i].uid === camera.uid) root.selectedIndex = i
    player.stop()
    player.source = ""
    if (!camera.online) {
      root.liveError = camera.name + " is offline"
      return
    }
    // Always ask the CLI: it caches Protect's URLs, and it makes sure the
    // encrypted relay the URL points at is actually running.
    var key = camera.uid + ":" + root.liveQuality
    root.stopProcess(streamProcess)
    streamProcess.cameraKey = key
    streamProcess.command = [root.cli, "stream", camera.uid, "--quality", root.liveQuality]
    streamProcess.running = true
  }

  // Most specific match first: a uid names exactly one camera, whatever a
  // console calls its other cameras. Hidden cameras count too.
  function findCamera(name) {
    var wanted = String(name || "")
    var lower = wanted.toLowerCase()
    var tests = [function(c) { return c.uid === wanted },
                 function(c) { return c.id === wanted },
                 function(c) { return String(c.name || "").toLowerCase() === lower }]
    for (var t = 0; t < tests.length; t++)
      for (var i = 0; i < allCameras.length; i++)
        if (tests[t](allCameras[i])) return allCameras[i]
    return null
  }

  function openLiveByName(name) {
    var camera = root.findCamera(name)
    root.open()
    if (camera) root.openLive(camera)
  }

  function openRecordingsByName(name) {
    var camera = root.findCamera(name)
    root.open()
    if (camera) root.openRecordings(camera, null, "live")
  }

  function stepLive(delta) {
    if (cameras.length === 0) return
    var next = (root.selectedIndex + delta + cameras.length) % cameras.length
    root.openLive(cameras[next])
  }

  function closeLive() {
    player.stop()
    player.source = ""
    root.stopProcess(streamProcess)
    root.leaveRecordings()
    root.liveCamera = null
    root.liveError = ""
  }

  function popOut(camera) {
    if (!camera) return
    if (root.recordingsView) {
      root.popOutClip()
      return
    }
    // From the live view the pop-out keeps its sound state; from the grid it
    // starts at the default.
    var sound = root.liveMode ? !root.muted : root.soundDefault
    // No camera name here: command lines are visible to other users, so
    // the helper looks the name up itself.
    Quickshell.execDetached([root.cli, "live", camera.uid,
                             "--quality", root.popoutQuality,
                             "--sound", sound ? "on" : "off"])
    root.closeLive()
    root.close()
  }

  function moveSelection(dx, dy) {
    if (cameras.length === 0) return
    var next = root.selectedIndex + dx + dy * root.columns
    root.selectedIndex = Math.max(0, Math.min(cameras.length - 1, next))
  }

  // ---- recordings ----
  //
  // A sub-view of one camera: `recordings` lists its detections of the last
  // day with thumbnails, `clip` exports one from Protect into the runtime
  // directory, and the same player that shows live video plays the file.
  // Protect only hands out recordings to a signed-in user, not to an API
  // key, so a console without a login shows a sign-in form instead.
  property bool recordingsView: false
  property string recordingsReturn: "live"     // where Esc goes: "live" or "alerts"
  property var recordings: []                   // newest first
  property bool recordingsLoaded: false
  property string recordingsError: ""
  property bool recordingsNeedLogin: false
  property string recordingsConsole: ""
  property string recordingsConsoleName: ""
  property int recordingIndex: -1
  property var pendingClip: null                // an alert to play once the list is in
  property var playingClip: null                // {start, end, eventStart, eventEnd}
  property string clipError: ""
  property string loginError: ""
  property bool enterPressed: false
  readonly property bool fetchingClip: clipProcess.running
  readonly property bool clipLoaded: recordingsView && playingClip !== null
                                     && player.mediaStatus !== MediaPlayer.NoMedia
                                     && player.mediaStatus !== MediaPlayer.LoadingMedia
                                     && player.mediaStatus !== MediaPlayer.InvalidMedia
                                     && player.mediaStatus !== MediaPlayer.EndOfMedia
  readonly property var selectedRecording: recordingIndex >= 0 && recordingIndex < recordings.length
                                           ? recordings[recordingIndex] : null

  function consoleHasRecordings(consoleId) {
    for (var i = 0; i < consoles.length; i++)
      if (consoles[i].id === consoleId) return consoles[i].recordings === true
    return false
  }

  function consoleHost(consoleId) {
    for (var i = 0; i < consoles.length; i++) if (consoles[i].id === consoleId) return consoles[i].host
    return ""
  }

  function eventWhen(seconds) {
    var date = new Date(seconds * 1000)
    var today = new Date()
    var day = date.toDateString() === today.toDateString() ? ""
            : date.toDateString() === new Date(today.getTime() - 86400000).toDateString() ? "Yesterday "
            : Qt.formatDate(date, "ddd ")
    return day + Qt.formatTime(date, "HH:mm:ss")
  }

  function clock(ms) {
    var total = Math.max(0, Math.floor(ms / 1000))
    var seconds = total % 60
    return Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds
  }

  // pending: an alert ({start, end}) to play straight away; from: where Esc returns.
  function openRecordings(camera, pending, from) {
    if (!camera) return
    if (!root.liveMode) root.muted = !root.soundDefault
    // Another camera's recordings: drop the old one's runs and sign-in form.
    root.leaveRecordings()
    player.stop()
    player.source = ""
    root.stopProcess(streamProcess)
    root.alertsView = false
    root.liveError = ""
    root.liveCamera = camera
    for (var i = 0; i < cameras.length; i++) if (cameras[i].uid === camera.uid) root.selectedIndex = i
    root.recordingsView = true
    root.recordingsReturn = from || "live"
    root.recordings = []
    root.recordingsLoaded = false
    root.recordingsError = ""
    root.recordingsNeedLogin = false
    root.recordingIndex = -1
    root.playingClip = null
    root.clipError = ""
    root.loginError = ""
    root.pendingClip = pending ? { id: pending.id || "", start: pending.start, end: pending.end || 0 } : null
    if (root.pendingClip) root.playClip(root.pendingClip.start, root.pendingClip.end)
    root.loadRecordings()
  }

  function loadRecordings() {
    root.stopProcess(recordingsProcess)
    recordingsProcess.uid = root.liveCamera.uid
    recordingsProcess.command = [root.cli, "recordings", root.liveCamera.uid, "--json"]
    recordingsProcess.running = true
  }

  // Leaves the recordings sub-view without touching the live player.
  function leaveRecordings() {
    if (!root.recordingsView) return
    root.stopProcess(recordingsProcess)
    root.stopProcess(clipProcess)
    root.stopProcess(loginProcess)
    loginPasswordField.text = ""
    root.recordingsView = false
    root.playingClip = null
    root.pendingClip = null
    root.clipError = ""
    root.loginError = ""
    player.stop()
    player.source = ""
    keyCatcher.forceActiveFocus()
  }

  // Esc: back to the alert log, or to the camera's live view.
  function backFromRecordings() {
    if (root.recordingsReturn === "alerts") {
      root.closeLive()
      root.alertsView = true
    } else {
      root.openLive(root.liveCamera)
    }
  }

  function playRecording(index) {
    var event = root.recordings[index]
    if (!event) return
    root.recordingIndex = index
    root.playClip(event.start, event.end || 0)
  }

  function playClip(start, end) {
    player.stop()
    player.source = ""
    root.clipError = ""
    root.playingClip = null
    root.stopProcess(clipProcess)
    clipProcess.key = root.liveCamera.uid + ":" + start
    clipProcess.eventStart = start
    clipProcess.eventEnd = end
    // Event times go in the environment, which only this user can read;
    // command lines are visible to everyone.
    clipProcess.environment = root.eventEnvironment(start, end)
    clipProcess.command = [root.cli, "clip", root.liveCamera.uid, "--quality", root.liveQuality, "--json"]
    clipProcess.running = true
  }

  // Space: pause and resume; at the end, play again from the start.
  function togglePause() {
    if (!root.playingClip) return
    if (player.playbackState === MediaPlayer.PlayingState) player.pause()
    else player.play()
  }

  function seekBy(seconds) {
    if (!root.clipLoaded || !player.seekable) return
    player.setPosition(Math.max(0, Math.min(player.duration - 100, player.position + seconds * 1000)))
  }

  function moveRecording(delta) {
    if (root.recordings.length === 0) return
    var next = root.recordingIndex < 0 ? 0 : root.recordingIndex + delta
    root.recordingIndex = Math.max(0, Math.min(root.recordings.length - 1, next))
    recordingsList.positionViewAtIndex(root.recordingIndex, ListView.Contain)
  }

  function eventEnvironment(start, end) {
    return { ELD_UNIFI_PROTECT_EVENT: JSON.stringify({ start: start, end: end || null }) }
  }

  // The clip in mpv at the pop-out quality: a separate export, then seekable.
  function popOutClip() {
    if (!root.playingClip) return
    var clip = root.playingClip
    Quickshell.execDetached({
      command: [root.cli, "clip", root.liveCamera.uid, "--quality", root.popoutQuality, "--play",
                "--sound", root.muted ? "off" : "on"],
      environment: root.eventEnvironment(clip.eventStart, clip.eventEnd)
    })
    root.closeLive()
    root.close()
  }

  function signIn() {
    if (loginProcess.running) return
    if (loginUserField.text.trim() === "" || loginPasswordField.text === "") {
      root.loginError = "Enter the username and the password"
      return
    }
    root.loginError = ""
    loginProcess.secret = loginUserField.text.trim() + "\n" + loginPasswordField.text + "\n"
    loginPasswordField.text = ""
    loginProcess.command = [root.cli, "login", root.recordingsConsole, "--stdin", "--json"]
    loginProcess.running = true
  }

  Process {
    id: recordingsProcess
    property string uid: ""
    property int stale: 0
    running: false
    stdout: StdioCollector { id: recordingsOut }
    stderr: StdioCollector { id: recordingsErr }
    onStarted: stale = 0
    onExited: function(exitCode) {
      if (stale > 0) { stale--; return }
      if (!root.recordingsView || !root.liveCamera || uid !== root.liveCamera.uid) return
      root.recordingsLoaded = true
      if (exitCode !== 0) {
        root.recordingsError = root.helperError(recordingsErr.text, "Could not list the recordings")
        return
      }
      try {
        var result = JSON.parse(recordingsOut.text)
        root.recordingsNeedLogin = result.needsLogin === true
        // Asked again because the console turned the saved login down.
        if (result.loginError) root.loginError = result.loginError
        root.recordingsConsole = result.console || ""
        root.recordingsConsoleName = result.consoleName || ""
        root.recordings = result.events || []
        root.recordingsError = ""
      } catch (error) {
        root.recordingsError = "Unexpected answer from the helper"
        return
      }
      if (root.recordingsNeedLogin) {
        root.pendingClip = null
        root.stopProcess(clipProcess)
        Qt.callLater(function() { loginUserField.forceActiveFocus() })
        return
      }
      // Coming from an alert: select the detection it belongs to, by its
      // Protect event id, else the one that started closest to it.
      if (root.pendingClip) {
        var best = -1
        for (var i = 0; i < root.recordings.length; i++) {
          var gap = Math.abs(root.recordings[i].start - root.pendingClip.start)
          if (root.pendingClip.id !== "" && root.recordings[i].id === root.pendingClip.id) { best = i; break }
          if (gap < 10 && (best < 0 || gap < Math.abs(root.recordings[best].start - root.pendingClip.start))) best = i
        }
        if (best >= 0) root.recordingIndex = best
        root.pendingClip = null
      } else if (root.recordingIndex < 0 && root.recordings.length > 0) {
        // Like Protect's own app: start on the newest detection.
        root.playRecording(0)
      }
    }
  }

  Process {
    id: clipProcess
    property string key: ""
    property real eventStart: 0
    property real eventEnd: 0
    property int stale: 0
    running: false
    stdout: StdioCollector { id: clipOut }
    stderr: StdioCollector { id: clipErr }
    onStarted: stale = 0
    onExited: function(exitCode) {
      if (stale > 0) { stale--; return }
      // Ignore a late answer for a clip the user has already left.
      if (!root.recordingsView || key !== root.liveCamera.uid + ":" + eventStart) return
      if (exitCode !== 0) {
        root.clipError = root.helperError(clipErr.text, "Could not fetch the recording")
        return
      }
      try {
        var clip = JSON.parse(clipOut.text)
        root.clipError = ""
        root.playingClip = { start: clip.start, end: clip.end, eventStart: eventStart, eventEnd: eventEnd }
        player.source = "file://" + clip.path
        player.play()
      } catch (error) {
        root.clipError = "Unexpected answer from the helper"
      }
    }
  }

  Process {
    id: loginProcess
    property string secret: ""
    property int stale: 0
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: loginOut }
    stderr: StdioCollector { id: loginErr }
    onStarted: {
      stale = 0
      write(secret)
      secret = ""
    }
    onExited: function(exitCode) {
      // Left while signing in: nothing to report, and the form is hidden.
      if (stale > 0) { stale--; return }
      if (!root.recordingsView) return
      if (exitCode !== 0) {
        root.loginError = root.helperError(loginErr.text, "Could not sign in")
        Qt.callLater(function() { loginPasswordField.forceActiveFocus() })
        return
      }
      root.recordingsNeedLogin = false
      root.reloadState()
      keyCatcher.forceActiveFocus()
      if (root.recordingsView) root.loadRecordings()
    }
  }

  // ---- state and actions ---------------------------------------------

  function applyState(text) {
    if (!text || text.trim() === "") return
    try { root.state = JSON.parse(text) } catch (error) { }
  }

  function applyIndex(text) {
    if (!text || text.trim() === "") return
    try { root.snapIndex = JSON.parse(text) } catch (error) { }
  }

  function reloadState() {
    if (pollProcess.running) return
    pollProcess.running = true
  }

  // Opens the console that hosts the selected camera, so right-click lands
  // on the right Protect when there are several.
  function openConsole() {
    var camera = cameras[root.selectedIndex]
    var args = [root.cli, "open"]
    if (camera && camera.console) args.push(camera.console)
    Quickshell.execDetached(args)
  }

  function setFavorite(camera, favorite) {
    Quickshell.execDetached(favorite ? [root.cli, "favorite", camera.uid]
                                     : [root.cli, "favorite", "--clear"])
  }

  function hideCamera(camera, hide) {
    Quickshell.execDetached([root.cli, hide ? "hide" : "unhide", camera.uid])
  }

  function toggleHideOffline() {
    Quickshell.execDetached([root.cli, "hide-offline", "toggle"])
  }

  // "window": a maximized window that keeps workspace switching and the
  // bar; "overlay": covers everything, every workspace included.
  readonly property string wallMode: setting("wallMode", "window") === "overlay" ? "overlay" : "window"

  function openWall() {
    Quickshell.execDetached([root.cli, "wall", "--mode", root.wallMode,
                             "--sound", root.soundDefault ? "on" : "off"])
    root.close()
  }

  // ---- setup, inside the panel ----
  //
  // Two steps, each a call to the helper: setup-probe fetches the console's
  // certificate fingerprint for the user to trust, then setup-save checks
  // the API key against that pinned certificate and stores it. The key is
  // handed to the helper on stdin, never as an argument, and the field is
  // cleared as soon as it is sent, the same way Omarchy's own network panel
  // handles Wi-Fi passwords.
  property string setupStep: ""          // "", "address", "key"
  property string setupHost: ""
  property string setupPin: ""
  property bool setupPinChanged: false
  property bool setupExisting: false
  property string setupSuggestedName: ""
  property string setupError: ""
  property string setupBusy: ""
  property string setupDone: ""
  readonly property bool settingUp: setupStep !== ""

  function openSetup() {
    root.closeLive()
    root.setupError = ""
    root.setupBusy = ""
    root.setupStep = "address"
    Qt.callLater(function() { if (addressField) addressField.forceActiveFocus() })
  }

  function addConsole() { root.openSetup() }

  function cancelSetup() {
    setupProbe.running = false
    keyField.text = ""
    root.setupStep = ""
    root.setupError = ""
    root.setupBusy = ""
    keyCatcher.forceActiveFocus()
  }

  function setupInTerminal() {
    Quickshell.execDetached(["xdg-terminal-exec", root.cli, "setup"])
    root.cancelSetup()
    root.close()
  }

  // An IP address or host name only: whatever is typed here reaches a
  // command line and DNS, so a mis-pasted API key must stop here.
  function plausibleHost(host) {
    var port = host.match(/^[^\[\]]*:(\d+)\/*$/)
    if (port && (Number(port[1]) < 1 || Number(port[1]) > 65535)) return false
    var name = host.replace(/^https?:\/\//, "").replace(/\/+$/, "").replace(/:\d{1,5}$/, "")
    if (/^\[[0-9A-Fa-f:.]+\]$/.test(name) || /^[0-9A-Fa-f:.]+$/.test(name) && name.indexOf(":") >= 0)
      return true
    if (/^[0-9.]+$/.test(name))
      return /^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)$/.test(name)
    var labels = name.replace(/\.$/, "").split(".")
    if (name.length > 253 || (labels.length === 1 && name.length > 24)) return false
    // Starts like an IP address but is not one: a key pasted after the IP.
    if (/^\d+$/.test(labels[0])) return false
    for (var i = 0; i < labels.length; i++) {
      var label = labels[i]
      if (!/^[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$/.test(label)) return false
      // A long run of letters and digits with no hyphen, or a shorter one
      // mixing cases and digits: a pasted key, not a host name.
      if (label.indexOf("-") < 0 && (label.length >= 30 ||
          (label.length >= 16 && /[A-Z]/.test(label) && /[a-z]/.test(label) && /\d/.test(label))))
        return false
    }
    return true
  }

  function probeConsole() {
    var host = addressField.text.trim()
    if (host === "" || setupProbe.running) return
    if (!root.plausibleHost(host)) {
      root.setupError = "That does not look like a console address: use its IP address or host name"
      return
    }
    root.setupError = ""
    root.setupBusy = "Reaching " + host + "…"
    setupProbe.command = [root.cli, "setup-probe", host]
    setupProbe.running = true
  }

  function connectConsole() {
    if (setupSave.running) return
    if (keyField.text.trim() === "" && !root.setupExisting) {
      root.setupError = "Paste the API key"
      return
    }
    root.setupError = ""
    root.setupBusy = "Checking the key with " + root.setupHost + "…"
    // Key, then name, on stdin: nothing typed here lands on a command line.
    setupSave.secret = keyField.text.trim() + "\n" + nameField.text.trim().replace(/[\r\n]/g, " ")
    keyField.text = ""
    setupSave.command = [root.cli, "setup-save", "--host", root.setupHost, "--pin", root.setupPin]
    setupSave.running = true
  }

  function helperError(text, fallback) {
    var message = text.trim().replace(/^eld-unifi-protect: /, "")
    return message !== "" ? message : fallback
  }

  Process {
    id: setupProbe
    running: false
    stdout: StdioCollector { id: probeOut }
    stderr: StdioCollector { id: probeErr }
    onExited: function(exitCode) {
      root.setupBusy = ""
      if (exitCode !== 0) {
        root.setupError = root.helperError(probeErr.text, "Could not reach the console")
        return
      }
      try {
        var result = JSON.parse(probeOut.text)
        root.setupHost = result.host
        root.setupPin = result.fingerprint
        root.setupPinChanged = result.changed === true
        root.setupExisting = result.existing === true
        root.setupSuggestedName = result.suggestedName || "Console"
        nameField.text = root.setupSuggestedName
        root.setupStep = "key"
        Qt.callLater(function() { keyField.forceActiveFocus() })
      } catch (error) {
        root.setupError = "Unexpected answer from the helper"
      }
    }
  }

  Process {
    id: setupSave
    property string secret: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: saveOut }
    stderr: StdioCollector { id: saveErr }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      root.setupBusy = ""
      if (exitCode !== 0) {
        root.setupError = root.helperError(saveErr.text, "Could not save the console")
        Qt.callLater(function() { keyField.forceActiveFocus() })
        return
      }
      try {
        var result = JSON.parse(saveOut.text)
        root.setupDone = "Connected to " + result.name + " · " + result.online + "/"
          + result.cameras + " cameras online · key stored in "
          + (result.keyStore === "keyring" ? "your keyring" : "your config file")
      } catch (error) {
        root.setupDone = "Console connected"
      }
      setupDoneTimer.restart()
      root.cancelSetup()
      root.reloadState()
    }
  }

  Timer {
    id: setupDoneTimer
    interval: 8000
    onTriggered: root.setupDone = ""
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    onLoadFailed: root.state = ({})
  }

  FileView {
    id: indexFile
    path: root.snapDir + "/index.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyIndex(text())
  }

  FileView {
    path: root.runtimeDir + "/alerts.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.alertsData = JSON.parse(text()) } catch (error) { } }
  }

  FileView {
    path: root.runtimeDir + "/alerts-ack.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var ack = JSON.parse(text())
        root.ackedAt = ack.ackedAt || 0
        root.clearedAt = ack.clearedAt || 0
      } catch (error) { }
    }
  }

  // Keeps "2 min ago" and the ten-minute tile marks current.
  Timer {
    interval: 30000
    repeat: true
    running: root.alerts.length > 0
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // The listener runs while any camera is armed, panel open or not. It exits
  // by itself once nothing is armed, or if the shell goes away; this
  // restarts it if it stops while cameras are still armed.
  Process {
    id: eventsProcess
    running: false
    command: [root.cli, "events", "--follow-parent"]
  }

  Timer {
    interval: 5000
    repeat: true
    triggeredOnStart: true
    running: root.configured && root.armedCount > 0
    onTriggered: if (!eventsProcess.running) eventsProcess.running = true
  }

  // FileView cannot watch a file that does not exist yet, and index.json
  // only appears after the first snapshot round (first run, or after the
  // runtime directory was cleared). Re-read it on the refresh interval while
  // the grid is showing, so tiles never stay stuck on "Loading".
  Timer {
    interval: root.snapshotSeconds * 1000
    repeat: true
    running: root.opened && !root.liveMode
    onTriggered: indexFile.reload()
  }

  Component.onCompleted: reloadState()

  onOpenedChanged: {
    if (opened) {
      root.reloadState()
      indexFile.reload()
      root.nowSec = Date.now() / 1000
      // Opening the panel is seeing the alert: select the camera, and
      // acknowledge so the bar stops flashing.
      var newest = root.latestAlert
      // Remember what was unseen, to mark it in the log, before acknowledging.
      root.seenBefore = root.ackedAt
      if (newest) {
        Quickshell.execDetached([root.cli, "alert", "--ack"])
        root.alertsView = true
      }
      if (root.selectedIndex >= cameras.length) root.selectedIndex = 0
      // The favourite sorts first; select it, and optionally go live.
      if (newest) {
        for (var a = 0; a < cameras.length; a++) if (cameras[a].uid === newest.uid) root.selectedIndex = a
      } else if (cameras.length && cameras[0].favorite) {
        root.selectedIndex = 0
        if (root.openFavoriteLive && cameras[0].online) root.openLive(cameras[0])
      }
    } else {
      root.closeLive()
      root.showHidden = false
      root.alertsView = false
      if (root.settingUp) root.cancelSetup()
    }
  }

  Process {
    id: pollProcess
    running: false
    command: [root.cli, "poll"]
    onExited: stateFile.reload()
  }

  // Background poll for the bar's health colour while the panel is closed.
  Timer {
    interval: 60000
    repeat: true
    running: !root.opened
    onTriggered: root.reloadState()
  }

  // Snapshot loop, alive only while the panel is open on the grid. In live
  // view the stream replaces it, so the console is not serving both.
  Process {
    id: watchProcess
    running: root.opened && root.configured && !root.liveMode
    command: [root.cli, "watch", "--interval", String(root.snapshotSeconds)]
  }

  Process {
    id: streamProcess
    property string cameraKey: ""
    property int stale: 0
    running: false
    stdout: StdioCollector { id: streamOut }
    stderr: StdioCollector { id: streamErr }
    onStarted: stale = 0
    onExited: function(exitCode) {
      if (stale > 0) { stale--; return }
      if (!root.liveMode) return
      if (exitCode !== 0) {
        root.liveError = streamErr.text.trim().replace(/^eld-unifi-protect: /, "")
                         || "could not open the stream"
        return
      }
      var url = streamOut.text.trim()
      // Ignore a late answer for a camera the user has already left.
      if (cameraKey !== root.liveCamera.uid + ":" + root.liveQuality) return
      player.source = url
      player.play()
    }
  }

  // Qt keeps the output that was the default when the shell started, so a
  // headset connected later never heard a thing; follow the default instead.
  MediaDevices { id: mediaDevices }

  MediaPlayer {
    id: player
    videoOutput: videoOutput
    audioOutput: AudioOutput {
      device: mediaDevices.defaultAudioOutput
      muted: root.muted
    }
    // Low-latency mode suits live network streams; for a local file (the
    // demo) it drops every frame, so only RTSP gets it.
    playbackOptions.playbackIntent: String(source).indexOf("rtsp") === 0
                                    ? PlaybackOptions.PlaybackIntent.LowLatencyStreaming
                                    : PlaybackOptions.PlaybackIntent.Playback
    playbackOptions.networkTimeoutMs: 8000
    onErrorOccurred: function(error, errorString) {
      if (root.recordingsView) root.clipError = errorString || "playback failed"
      else if (root.liveMode) root.liveError = errorString || "playback failed"
    }
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Util.alpha(foreground, 0.05)

  component ActionButton: Button {
    property string label: ""
    property bool outlined: false
    signal triggered()

    text: label
    bordered: outlined
    foreground: root.foreground
    accent: Color.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    opacity: enabled ? 1 : 0.4
    onClicked: if (enabled) triggered()
  }

  // Two images, swapped once the new frame has decoded, so a refresh never
  // flashes an empty tile between snapshots.
  component Snapshot: Item {
    id: snap
    property string url: ""
    property int front: 0
    clip: true

    onUrlChanged: {
      if (url === "") return
      var back = front === 0 ? imageB : imageA
      back.source = url
    }

    Image {
      id: imageA
      anchors.fill: parent
      fillMode: root.framingFill ? Image.PreserveAspectCrop : Image.PreserveAspectFit
      asynchronous: true
      cache: false
      sourceSize.width: 960
      visible: snap.front === 0
      onStatusChanged: if (status === Image.Ready && snap.front !== 0) snap.front = 0
    }

    Image {
      id: imageB
      anchors.fill: parent
      fillMode: root.framingFill ? Image.PreserveAspectCrop : Image.PreserveAspectFit
      asynchronous: true
      cache: false
      sourceSize.width: 960
      visible: snap.front === 1
      onStatusChanged: if (status === Image.Ready && snap.front !== 1) snap.front = 1
    }
  }

  // Lets text stay legible over a bright frame.
  component Scrim: Rectangle {
    gradient: Gradient {
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.7) }
    }
  }

  readonly property int cardWidth: Style.space(root.columns === 1 ? 520 : (root.columns * 340))

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.liveMode ? Math.max(root.cardWidth, Style.space(860))
                                                         : root.cardWidth)
    contentHeight: panel.fittedContentHeight(
      headerRow.implicitHeight + Style.space(10)
        + (root.liveMode ? liveView.implicitHeight
           : root.settingUp ? setupCard.implicitHeight
           : root.alertsView ? alertsColumn.implicitHeight : content.implicitHeight),
      Style.space(1000))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing an address or a key must not trigger the panel's letter
      // shortcuts; Esc in a setup field cancels setup instead.
      blocked: root.settingUp || loginUserField.activeFocus || loginPasswordField.activeFocus

      onCloseRequested: root.recordingsView ? root.backFromRecordings()
                        : root.liveMode ? root.closeLive()
                        : root.alertsView ? (root.alertsView = false) : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.recordingsView) {
          if (dy !== 0) root.moveRecording(dy)
          else root.seekBy(dx * 5)
        }
        else if (root.liveMode) { if (dx !== 0) root.stepLive(dx) }
        else root.moveSelection(dx, dy)
      }
      onReturnRequested: root.enterPressed = true
      onActivateRequested: {
        var enter = root.enterPressed
        root.enterPressed = false
        if (root.recordingsView) {
          // Enter plays the selected detection (again); Space pauses.
          var selected = root.selectedRecording
          var current = root.playingClip && selected && root.playingClip.eventStart === selected.start
          if ((enter || !root.playingClip) && !current) root.playRecording(root.recordingIndex)
          else if (current && (enter || player.mediaStatus === MediaPlayer.EndOfMedia)) {
            player.setPosition(0)
            player.play()
          }
          else root.togglePause()
          return
        }
        if (!root.liveMode && root.cameras.length > 0)
          root.openLive(root.cameras[root.selectedIndex])
      }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (key === "m") root.muted = !root.muted
        else if (key === "r" && root.liveMode)
          root.recordingsView ? root.backFromRecordings() : root.openRecordings(root.liveCamera, null, "live")
        else if (key === "w") root.openWall()
        else if (key === "a" && !root.liveMode && root.configured) root.alertsView = !root.alertsView
        else if (key === "p") {
          var target = root.liveMode ? root.liveCamera : root.cameras[root.selectedIndex]
          root.popOut(target)
        }
        else if (key >= "1" && key <= "9" && Number(key) <= root.cameras.length)
          root.openLive(root.cameras[Number(key) - 1])
      }

      Column {
        id: panelBody
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- header ----
        Row {
          id: headerRow
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width - headerActions.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: root.liveMode ? root.liveCamera.name.toUpperCase()
                  + (root.multiConsole ? "  ·  " + root.liveCamera.consoleName.toUpperCase() : "")
                  + (root.recordingsView ? "  ·  RECORDINGS" : "")
                : root.alertsView ? "ALERTS" + (root.logAlerts.length ? "  ·  " + root.logAlerts.length : "")
                : "UNIFI PROTECT" + (root.configured && root.shownCameras.length
                    ? "  ·  " + root.onlineCount + "/" + root.shownCameras.length + " ONLINE" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Row {
            id: headerActions
            spacing: Style.space(6)

            ActionButton {
              visible: root.liveMode
              label: root.muted ? "Unmute" : "Mute"
              outlined: true
              onTriggered: root.muted = !root.muted
            }

            ActionButton {
              visible: root.liveMode && (!root.recordingsView || root.playingClip !== null)
              label: "Pop out"
              outlined: true
              onTriggered: root.popOut(root.liveCamera)
            }

            ActionButton {
              visible: root.liveMode
              label: root.recordingsView ? "Live" : "Recordings"
              outlined: true
              onTriggered: root.recordingsView ? root.openLive(root.liveCamera)
                                               : root.openRecordings(root.liveCamera, null, "live")
            }

            ActionButton {
              visible: root.liveMode
              label: "Back"
              outlined: true
              onTriggered: root.recordingsView && root.recordingsReturn === "alerts"
                           ? root.backFromRecordings() : root.closeLive()
            }

            ActionButton {
              visible: root.alertsView && root.logAlerts.length > 0
              label: "Clear"
              outlined: true
              onTriggered: root.clearAlerts()
            }

            ActionButton {
              visible: root.alertsView
              label: "Back"
              outlined: true
              onTriggered: root.alertsView = false
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && !root.alertsView && root.configured
                       && (root.armedCount > 0 || root.logAlerts.length > 0)
              label: "Alerts"
              outlined: true
              onTriggered: root.alertsView = true
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && !root.alertsView && root.configured && root.shownCameras.length > 0
              label: "Wall"
              outlined: true
              onTriggered: root.openWall()
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && !root.alertsView && root.configured
              label: "Add console"
              outlined: true
              onTriggered: root.addConsole()
            }

            ActionButton {
              visible: !root.liveMode && !root.settingUp && !root.alertsView && root.configured
              label: "Protect"
              outlined: true
              onTriggered: root.openConsole()
            }
          }
        }

        // ---- live view ----
        Column {
          id: liveView
          visible: root.liveMode
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            width: parent.width
            height: Math.round(width * 9 / 16)
            radius: Style.cornerRadius
            color: "black"
            clip: true

            // The last snapshot holds the frame while the stream connects;
            // in recordings, the selected detection's thumbnail.
            Snapshot {
              anchors.fill: parent
              visible: root.recordingsView ? !root.clipLoaded : !root.playing
              opacity: 0.6
              url: !root.liveMode ? ""
                   : root.recordingsView ? (root.selectedRecording && root.selectedRecording.thumb
                                            ? "file://" + root.selectedRecording.thumb : "")
                   : root.snapshotUrl(root.liveCamera.uid)
            }

            VideoOutput {
              id: videoOutput
              anchors.fill: parent
              fillMode: root.framingFill ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
            }

            Text {
              anchors.centerIn: parent
              visible: root.recordingsView ? !root.clipLoaded : !root.playing
              width: parent.width - Style.space(40)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              readonly property string failure: root.recordingsView
                ? (root.clipError || root.recordingsError) : root.liveError
              text: failure !== "" ? failure
                    : !root.recordingsView ? "Connecting…"
                    : root.fetchingClip ? "Fetching the recording from Protect…"
                    : player.mediaStatus === MediaPlayer.EndOfMedia ? "End of the recording · Space plays it again"
                    : root.recordingsNeedLogin ? "Sign in below to watch recordings"
                    : !root.recordingsLoaded ? "Loading detections…"
                    : root.recordings.length === 0 ? "No detections in the last 24 hours"
                    : "Enter plays the selected detection"
              color: failure !== "" ? root.urgent : "white"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // REC badge: a recording, with the time it shows, never live.
            Rectangle {
              visible: root.recordingsView && root.clipLoaded
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              width: recLabel.implicitWidth + Style.space(14)
              height: recLabel.implicitHeight + Style.space(6)
              radius: height / 2
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                id: recLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: (player.playbackState === MediaPlayer.PlayingState ? "▶ " : "❚❚ ")
                      + "REC  " + (root.playingClip
                                   ? root.eventWhen(root.playingClip.start + player.position / 1000) : "")
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            // LIVE badge: a frozen stream must never pass for a live one.
            // Top right: UniFi cameras burn their timestamp in at top left.
            Rectangle {
              visible: root.playing && !root.recordingsView
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              width: liveLabel.implicitWidth + Style.space(14)
              height: liveLabel.implicitHeight + Style.space(6)
              radius: height / 2
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                id: liveLabel
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "● LIVE"
                color: "#ff5555"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            MouseArea {
              anchors.fill: parent
              onClicked: if (root.recordingsView) root.togglePause()
              onDoubleClicked: root.popOut(root.liveCamera)
            }
          }

          // Playhead of a recording: click or drag to seek.
          Row {
            visible: root.recordingsView && root.playingClip !== null
            width: parent.width
            spacing: Style.space(8)

            Text {
              id: clipTime
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.clock(player.position) + " / " + root.clock(player.duration)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              width: parent.width - clipTime.width - parent.spacing
              height: Style.space(16)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Util.alpha(root.foreground, 0.15)

                Rectangle {
                  width: player.duration > 0 ? parent.width * Math.min(1, player.position / player.duration) : 0
                  height: parent.height
                  radius: parent.radius
                  color: Color.accent
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                function seekTo(x) {
                  if (player.duration > 0 && player.seekable)
                    player.setPosition(Math.max(0, Math.min(1, x / width)) * player.duration)
                }
                onPressed: function(mouse) { seekTo(mouse.x) }
                onPositionChanged: function(mouse) { if (pressed) seekTo(mouse.x) }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            text: root.recordingsView
                  ? "↑/↓ choose  ·  Enter play  ·  Space pause  ·  ←/→ 5 s  ·  M mute  ·  P pop out  ·  Esc "
                    + (root.recordingsReturn === "alerts" ? "alerts" : "live")
                  : "←/→ switch camera  ·  1–9 jump  ·  M mute  ·  R recordings  ·  P or double-click pop out  ·  Esc back"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // ---- detections ----
          ListView {
            id: recordingsList
            visible: root.recordingsView && !root.recordingsNeedLogin && root.recordings.length > 0
            width: parent.width
            height: visible ? Math.min(root.recordings.length, 4) * Style.space(68) : 0
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds
            model: root.recordingsView ? root.recordings : []

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
              id: recordingRow
              required property var modelData
              required property int index
              readonly property bool selected: index === root.recordingIndex
              readonly property bool current: root.playingClip !== null
                                              && root.playingClip.eventStart === modelData.start
              width: recordingsList.width - Style.space(8)
              height: Style.space(64)
              radius: Style.cornerRadius
              color: recordingMouse.containsMouse || selected ? root.surface : "transparent"
              border.width: selected ? Math.max(1, Style.space(1)) : 0
              border.color: Color.accent

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(5)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(96)
                  height: Style.space(54)
                  radius: Style.cornerRadius
                  color: root.surface
                  clip: true

                  Image {
                    anchors.fill: parent
                    source: recordingRow.modelData.thumb ? "file://" + recordingRow.modelData.thumb : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    sourceSize.width: 192
                  }
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(96) - parent.spacing
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: (recordingRow.current ? "▶ " : "") + root.alertLabel(recordingRow.modelData.kind)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: {
                      var e = recordingRow.modelData
                      var parts = [root.eventWhen(e.start)]
                      parts.push(e.end ? Math.max(1, Math.round(e.end - e.start)) + " s" : "ongoing")
                      if (e.score) parts.push(e.score + "% sure")
                      return parts.join("  ·  ")
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                id: recordingMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.playRecording(recordingRow.index)
              }
            }
          }

          // ---- sign-in for recordings ----
          Column {
            visible: root.recordingsView && root.recordingsNeedLogin
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: "Protect only gives recordings to a signed-in user; API keys can't fetch them. "
                  + "Sign in to " + root.recordingsConsoleName + " with a local UniFi account made for "
                  + "this: on https://" + (root.liveCamera ? root.consoleHost(root.liveCamera.console) : "")
                  + ", Admins & Users → Add, tick \"Restrict to local access only\", and give it a "
                  + "view-only Protect role. The password goes to your keyring."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              id: loginUserField
              width: parent.width
              placeholderText: "Username"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: loginPasswordField.forceActiveFocus()
              Keys.onEscapePressed: root.backFromRecordings()
            }

            TextField {
              id: loginPasswordField
              width: parent.width
              password: true
              placeholderText: "Password"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: root.signIn()
              Keys.onEscapePressed: root.backFromRecordings()
            }

            Text {
              visible: root.loginError !== "" || loginProcess.running
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.loginError !== "" ? root.loginError : "Signing in…"
              color: root.loginError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            ActionButton {
              label: "Sign in"
              enabled: !loginProcess.running
              onTriggered: root.signIn()
            }
          }
        }

        // ---- setup ----
        Column {
          id: setupCard
          visible: root.settingUp
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.configured ? "Add a UniFi Protect console" : "Connect your UniFi Protect console"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          // Step 1: address.
          Text {
            visible: root.setupStep === "address"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "The console's local address: a Dream Machine, Cloud Gateway, NVR or "
                + "Cloud Key running Protect. Each console needs its own setup."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: addressField
            visible: root.setupStep === "address"
            width: parent.width
            placeholderText: "192.168.1.1"
            text: root.configured ? "" : "192.168.1.1"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.probeConsole()
            Keys.onEscapePressed: root.cancelSetup()
          }

          // Step 2: trust the certificate, paste the key.
          Text {
            visible: root.setupStep === "key"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WrapAnywhere
            text: root.setupHost + " presents this certificate (SHA-256):\n" + root.setupPin
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.setupStep === "key" && root.setupPinChanged
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This differs from the certificate trusted before. Continue only if you "
                + "expected it (firmware update, factory reset)."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.setupStep === "key"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Connecting trusts it: from then on the plugin refuses any other certificate "
                + "from this address, so the key is only ever sent to this console.\n\n"
                + "Create an API key on the console: open https://" + root.setupHost
                + ", click Integrations at the bottom of the left sidebar (older UniFi OS: "
                + "Settings, scroll the tabs sideways), then Create API Key. It is shown once."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: keyField
            visible: root.setupStep === "key"
            width: parent.width
            password: true
            placeholderText: root.setupExisting ? "API key (leave empty to keep the current one)"
                                                : "API key (paste with Super+V)"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.connectConsole()
            Keys.onEscapePressed: root.cancelSetup()
          }

          TextField {
            id: nameField
            visible: root.setupStep === "key"
            width: parent.width
            placeholderText: "Name, e.g. NVR"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.connectConsole()
            Keys.onEscapePressed: root.cancelSetup()
          }

          Text {
            visible: root.setupError !== "" || root.setupBusy !== ""
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.setupError !== "" ? root.setupError : root.setupBusy
            color: root.setupError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.space(6)

            ActionButton {
              visible: root.setupStep === "address"
              label: "Next"
              enabled: !setupProbe.running && addressField.text.trim() !== ""
              onTriggered: root.probeConsole()
            }

            ActionButton {
              visible: root.setupStep === "key"
              label: "Connect"
              enabled: !setupSave.running
              onTriggered: root.connectConsole()
            }

            ActionButton {
              label: root.setupStep === "key" ? "Back" : "Cancel"
              outlined: true
              enabled: !setupSave.running
              onTriggered: {
                if (root.setupStep === "key") {
                  keyField.text = ""
                  root.setupError = ""
                  root.setupStep = "address"
                  addressField.text = root.setupHost
                } else {
                  root.cancelSetup()
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Prefer the terminal? Run setup there instead"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: setupTerminalMouse.containsMouse

            MouseArea {
              id: setupTerminalMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setupInTerminal()
            }
          }
        }

        // ---- alert log ----
        Flickable {
          id: alertsScroll
          visible: root.alertsView && !root.liveMode
          width: parent.width
          height: parent.height - headerRow.height - panelBody.spacing
          contentHeight: alertsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: alertsColumn
            width: alertsScroll.width
            spacing: Style.space(4)

            Text {
              visible: root.logAlerts.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.armedCount > 0
                    ? "No alerts in the last 24 hours."
                    : "No alerts. Arm a camera with the bell on its tile to be told when it sees a person, a vehicle or a doorbell ring."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              topPadding: Style.space(8)
              bottomPadding: Style.space(8)
            }

            Repeater {
              model: root.alertsView ? root.logAlerts : []

              Rectangle {
                id: alertRow
                required property var modelData
                readonly property bool isNew: modelData.start > root.seenBefore
                width: alertsColumn.width
                height: Style.space(64)
                radius: Style.cornerRadius
                color: alertMouse.containsMouse ? root.surface : "transparent"

                Row {
                  anchors.fill: parent
                  anchors.margins: Style.space(5)
                  spacing: Style.space(10)

                  Rectangle {
                    width: Style.space(96)
                    height: Style.space(54)
                    radius: Style.cornerRadius
                    color: root.surface
                    clip: true

                    Image {
                      anchors.fill: parent
                      // Only a plain "<id>.jpg" inside the alert folder, as the helper writes.
                      source: /^[A-Za-z0-9_-]{1,64}\.jpg$/.test(alertRow.modelData.image || "")
                              ? "file://" + root.runtimeDir + "/alerts/" + alertRow.modelData.image : ""
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      sourceSize.width: 192
                    }
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(96) - parent.spacing
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: (alertRow.isNew ? "● " : "") + root.alertLabel(alertRow.modelData.kind)
                            + "  ·  " + alertRow.modelData.camera
                      color: alertRow.isNew ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: {
                        var a = alertRow.modelData
                        var parts = [Qt.formatTime(new Date(a.start * 1000), "HH:mm:ss") + " (" + root.ago(a.start) + ")"]
                        parts.push(a.end ? Math.max(1, Math.round(a.end - a.start)) + " s" : "ongoing")
                        if (root.multiConsole) parts.push(a.consoleName)
                        return parts.join("  ·  ")
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }

                MouseArea {
                  id: alertMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openAlert(alertRow.modelData)
                }
              }
            }

            Text {
              visible: root.logAlerts.length > 0
              width: parent.width
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              text: (root.consoles.some(function(c) { return c.recordings === true })
                     ? "Click an alert to watch its recording" : "Click an alert to watch that camera live")
                    + "  ·  last 24 hours  ·  Esc back"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              topPadding: Style.space(6)
            }
          }
        }

        // ---- grid ----
        Flickable {
          id: bodyScroll
          visible: !root.liveMode && !root.settingUp && !root.alertsView
          width: parent.width
          height: parent.height - headerRow.height - panelBody.spacing
          contentHeight: content.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: content
            width: bodyScroll.width
            spacing: Style.space(10)

            Text {
              visible: root.setupDone !== ""
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.setupDone
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // ---- first-run ----
            Rectangle {
              visible: !root.configured
              width: parent.width
              height: visible ? setupColumn.implicitHeight + Style.space(24) : 0
              radius: Style.cornerRadius
              color: root.surface

              Column {
                id: setupColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(12)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: "Connect your UniFi Protect console"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: "Setup asks for your console's address and an API key, and keeps "
                      + "the key in your keyring (or a file only you can read)."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                ActionButton {
                  label: "Run setup"
                  onTriggered: root.openSetup()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.armedCount > 0 && root.alertProblems.length > 0
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Alerts paused · " + root.alertProblems.join("; ")
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              visible: root.stale
              width: parent.width
              wrapMode: Text.WordWrap
              text: (root.state.error || "Console unreachable")
                  + " · its cameras show their last snapshot"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              visible: root.configured && !root.stale && root.cameras.length === 0
                       && root.hiddenCount === 0
              width: parent.width
              text: "No cameras on this console."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Grid {
              id: grid
              visible: root.configured
              width: parent.width
              columns: Math.min(root.columns, Math.max(1, root.cameras.length))
              spacing: Style.space(8)

              readonly property real tileWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: root.configured ? root.cameras : []

                Rectangle {
                  id: tile
                  required property var modelData
                  required property int index
                  readonly property bool selected: index === root.selectedIndex

                  width: grid.tileWidth
                  height: Math.round(width * 9 / 16)
                  radius: Style.cornerRadius
                  color: root.surface
                  clip: true
                  readonly property var alert: root.recentAlert(modelData.uid)
                  readonly property bool armed: modelData.alerts && modelData.alerts.length > 0
                  border.width: alert || selected || tileMouse.containsMouse ? Math.max(1, Style.space(2)) : 0
                  border.color: alert ? root.urgent : Color.accent

                  readonly property bool hiddenTile: root.isHidden(modelData)

                  Snapshot {
                    anchors.fill: parent
                    anchors.margins: tile.border.width
                    url: root.snapshotUrl(tile.modelData.uid)
                    opacity: (tile.modelData.online ? 1 : 0.3) * (tile.hiddenTile ? 0.4 : 1)
                  }

                  Rectangle {
                    visible: tile.hiddenTile
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: Style.space(8)
                    width: hiddenLabel.implicitWidth + Style.space(12)
                    height: hiddenLabel.implicitHeight + Style.space(4)
                    radius: height / 2
                    color: Qt.rgba(0, 0, 0, 0.6)

                    Text {
                      id: hiddenLabel
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: tile.modelData.hidden ? "HIDDEN" : "HIDDEN · OFFLINE"
                      color: "white"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: !tile.modelData.online || !root.snapIndex[tile.modelData.uid]
                    textFormat: Text.PlainText
                    text: tile.modelData.online ? "Loading…" : "Offline"
                    color: tile.modelData.online ? root.dim : root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Scrim {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Style.space(40)
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.right: bellButton.left
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(8)
                    textFormat: Text.PlainText
                    text: (tile.index < 9 ? (tile.index + 1) + "  " : "")
                        + (tile.modelData.favorite ? "★ " : "") + (tile.armed ? "\uf0f3 " : "")
                        + tile.modelData.name
                        + (root.multiConsole ? "  ·  " + tile.modelData.consoleName : "")
                    color: "white"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    id: tileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = tile.index
                    onClicked: root.openLive(tile.modelData)
                  }

                  // What was seen, and when, while the camera's alert is recent.
                  Rectangle {
                    visible: tile.alert !== null
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Style.space(8)
                    width: alertBadge.implicitWidth + Style.space(12)
                    height: alertBadge.implicitHeight + Style.space(4)
                    radius: height / 2
                    color: root.urgent

                    Text {
                      id: alertBadge
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: tile.alert ? root.alertLabel(tile.alert.kind) + " · " + root.ago(tile.alert.start) : ""
                      color: "white"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  PanelActionButton {
                    id: bellButton
                    anchors.right: starButton.left
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(4)
                    visible: tile.modelData.online || tile.armed
                    property bool pointerInside: false
                    opacity: tileMouse.containsMouse || pointerInside ? 1 : 0
                    onHovered: function(isHovered) { pointerInside = isHovered }
                    iconText: tile.armed ? "\uf0f3" : "\uf1f6"
                    tooltipText: tile.armed ? "Stop alerts for " + tile.modelData.name
                                 : "Alert on a person, vehicle or doorbell at " + tile.modelData.name
                    foreground: "white"
                    fontFamily: root.fontFamily
                    onClicked: root.setArmed(tile.modelData, !tile.armed)
                  }

                  PanelActionButton {
                    id: starButton
                    anchors.right: hideButton.visible ? hideButton.left
                                 : (popButton.visible ? popButton.left : parent.right)
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(4)
                    property bool pointerInside: false
                    opacity: tileMouse.containsMouse || pointerInside ? 1 : 0
                    onHovered: function(isHovered) { pointerInside = isHovered }
                    iconText: tile.modelData.favorite ? "\uf005" : "\uf006"
                    tooltipText: tile.modelData.favorite ? "Unset favourite"
                                 : "Open the panel on " + tile.modelData.name
                    foreground: "white"
                    fontFamily: root.fontFamily
                    onClicked: root.setFavorite(tile.modelData, !tile.modelData.favorite)
                  }

                  PanelActionButton {
                    id: hideButton
                    anchors.right: popButton.visible ? popButton.left : parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(4)
                    // Cameras hidden only for being offline come back via
                    // "Show offline", not one by one.
                    visible: !tile.hiddenTile || tile.modelData.hidden
                    property bool pointerInside: false
                    opacity: tileMouse.containsMouse || pointerInside ? 1 : 0
                    onHovered: function(isHovered) { pointerInside = isHovered }
                    iconText: tile.modelData.hidden ? "\uf06e" : "\uf070"
                    tooltipText: (tile.modelData.hidden ? "Show " : "Hide ") + tile.modelData.name
                    foreground: "white"
                    fontFamily: root.fontFamily
                    onClicked: root.hideCamera(tile.modelData, !tile.modelData.hidden)
                  }

                  PanelActionButton {
                    id: popButton
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(4)
                    visible: tile.modelData.online
                    property bool pointerInside: false
                    opacity: tileMouse.containsMouse || pointerInside ? 1 : 0
                    onHovered: function(isHovered) { pointerInside = isHovered }
                    iconText: ""
                    tooltipText: "Open " + tile.modelData.name + " in a window"
                    foreground: "white"
                    fontFamily: root.fontFamily
                    onClicked: root.popOut(tile.modelData)
                  }
                }
              }
            }

            Row {
              visible: root.configured && root.allCameras.length > 0
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              ActionButton {
                visible: root.armedCount > 0
                readonly property bool on: root.state.alertNotify !== false
                label: on ? "Notifications on" : "Notifications off"
                outlined: true
                onTriggered: Quickshell.execDetached([root.cli, "alert", "--notify", on ? "off" : "on"])
              }

              ActionButton {
                label: root.hideOffline ? "Show offline" : "Hide offline"
                outlined: true
                onTriggered: root.toggleHideOffline()
              }

              ActionButton {
                visible: root.hiddenCount > 0 || root.showHidden
                label: root.showHidden ? "Done" : "Show hidden (" + root.hiddenCount + ")"
                outlined: !root.showHidden
                onTriggered: root.showHidden = !root.showHidden
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.configured && root.cameras.length > 0
              width: parent.width
              text: "Click or Enter for live  ·  P pop out  ·  W wall  ·  "
                  + root.consoles.map(function(c) { return c.name }).join(", ")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }

            // Version, linking to its release notes.
            Text {
              visible: root.pluginVersion !== ""
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "UniFi Protect for Omarchy v" + root.pluginVersion
              color: versionMouse.containsMouse && root.releaseUrl !== "" ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: versionMouse.containsMouse && root.releaseUrl !== ""

              MouseArea {
                id: versionMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.releaseUrl !== ""
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  Quickshell.execDetached(["xdg-open", root.releaseUrl])
                  root.close()
                }
              }
            }
          }
        }
      }
    }
  }
}
