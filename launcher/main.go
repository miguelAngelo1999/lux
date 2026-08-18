// lux_launcher.exe — single entry point for all Windows versions.
//
// Windows 10+ (build 18362+): detects and launches the Flutter lux.exe.
//   The Flutter app manages lux_core itself; this process exits after handoff.
//
// Windows 7/8/Server 2008 R2/2012/2012 R2:
//   Starts lux_core.exe, shows a system tray icon, opens the browser dashboard.
//
// Tray menu: Open Dashboard | Start | Stop | ──── | Exit
// Tray icon: green when running, grey when stopped.
package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/getlantern/systray"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// ── tiny embedded BMP icons (1×1 px, green / grey) ──────────────────────────
// Replace with real multi-resolution .ico bytes for production.

var iconGreen = []byte{
	0x42, 0x4d, 0x3e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00,
	0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
	0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, // green BGR
}

var iconGrey = []byte{
	0x42, 0x4d, 0x3e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36, 0x00,
	0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
	0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x00, 0x00, // grey BGR
}

// ── globals ──────────────────────────────────────────────────────────────────

var (
	exeDir  string
	apiPort = 8000

	mu       sync.Mutex
	coreProc *exec.Cmd
	running  bool
	secret   string
)

func main() {
	exeDir, _ = filepath.Abs(filepath.Dir(os.Args[0]))

	if isWin10Plus() {
		// Hand off to the Flutter UI which manages lux_core itself.
		flutterExe := filepath.Join(exeDir, "lux.exe")
		if _, err := os.Stat(flutterExe); err == nil {
			cmd := exec.Command(flutterExe, os.Args[1:]...)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := cmd.Start(); err == nil {
				cmd.Wait()
				return
			}
		}
		// lux.exe not found — fall through to legacy tray mode
	}

	// Legacy mode: run core + tray ourselves
	systray.Run(onReady, onExit)
}

// ── tray lifecycle ───────────────────────────────────────────────────────────

func onReady() {
	icon := loadAppIcon()
	if icon == nil {
		icon = iconGrey
	}
	systray.SetIcon(icon)
	systray.SetTitle("Lux")
	systray.SetTooltip("Lux — stopped")

	mDash := systray.AddMenuItem("Open Dashboard", "Open the Lux web dashboard in your browser")
	systray.AddSeparator()
	mStart := systray.AddMenuItem("Start", "Start the proxy core")
	mStop := systray.AddMenuItem("Stop", "Stop the proxy core")
	mStop.Disable()
	systray.AddSeparator()
	mExit := systray.AddMenuItem("Exit", "Quit Lux")

	// Auto-start core on launch
	go func() {
		startCore()
		updateTray(mStart, mStop)
	}()

	// Watchdog: restart core if it dies unexpectedly
	go func() {
		for {
			time.Sleep(30 * time.Second)
			mu.Lock()
			needRestart := running && (coreProc == nil || coreProc.ProcessState != nil)
			mu.Unlock()
			if needRestart {
				startCore()
				updateTray(mStart, mStop)
			}
		}
	}()

	// Event loop
	for {
		select {
		case <-mDash.ClickedCh:
			openDashboard()
		case <-mStart.ClickedCh:
			startCore()
			updateTray(mStart, mStop)
		case <-mStop.ClickedCh:
			stopCore()
			updateTray(mStart, mStop)
		case <-mExit.ClickedCh:
			stopCore()
			systray.Quit()
			return
		}
	}
}

func onExit() {}

// ── core management ──────────────────────────────────────────────────────────

func startCore() {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return
	}

	coreExe := filepath.Join(exeDir, "data", "flutter_assets", "assets", "bin", "lux_core.exe")
	if _, err := os.Stat(coreExe); err != nil {
		coreExe = filepath.Join(exeDir, "lux_core.exe")
	}

	s := persistedSecret()
	cmd := exec.Command(coreExe,
		fmt.Sprintf(`-home_dir="%s"`, luxHomeDir()),
		fmt.Sprintf("-port=%d", apiPort),
		fmt.Sprintf("-secret=%s", s),
	)
	cmd.Dir = exeDir
	if err := cmd.Start(); err != nil {
		return
	}
	coreProc = cmd
	secret = s
	running = true
	go func() { cmd.Wait() }()
}

func stopCore() {
	mu.Lock()
	defer mu.Unlock()
	if !running || coreProc == nil {
		return
	}
	_ = coreProc.Process.Kill()
	coreProc = nil
	running = false
}

// ── dashboard ────────────────────────────────────────────────────────────────

func openDashboard() {
	mu.Lock()
	tok := secret
	mu.Unlock()

	// If we don't have the token in memory, read it from the log
	if tok == "" {
		tok = tokenFromLog()
	}

	url := fmt.Sprintf("http://localhost:%d/?token=%s", apiPort, tok)
	// Use rundll32 to open the URL — works on all Windows versions
	exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}

func tokenFromLog() string {
	logPath := filepath.Join(luxHomeDir(), "logs", "core.log")
	data, err := os.ReadFile(logPath)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(data), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		idx := strings.Index(lines[i], "token=")
		if idx < 0 {
			continue
		}
		rest := lines[i][idx+6:]
		end := strings.IndexAny(rest, `"& `)
		if end > 0 {
			return rest[:end]
		}
		return strings.TrimSpace(rest)
	}
	return ""
}

// ── tray helpers ─────────────────────────────────────────────────────────────

func updateTray(mStart, mStop *systray.MenuItem) {
	mu.Lock()
	r := running
	mu.Unlock()

	if r {
		if icon := loadAppIcon(); icon != nil {
			systray.SetIcon(icon)
		} else {
			systray.SetIcon(iconGreen)
		}
		systray.SetTooltip("Lux — running")
		mStart.Disable()
		mStop.Enable()
	} else {
		systray.SetIcon(iconGrey)
		systray.SetTooltip("Lux — stopped")
		mStart.Enable()
		mStop.Disable()
	}
}

func loadAppIcon() []byte {
	p := filepath.Join(exeDir, "data", "flutter_assets", "assets", "app_icon.ico")
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	return b
}

// ── utilities ────────────────────────────────────────────────────────────────

func isWin10Plus() bool {
	major, _, _ := windows.RtlGetNtVersionNumbers()
	return major >= 10
}

func luxHomeDir() string {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		appData = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Roaming")
	}
	return filepath.Join(appData, "com.github.igoogolx", "lux", "1.0")
}

// persistedSecret stores the API secret in the registry so it survives
// launcher restarts and remains consistent with lux_core's expectation.
func persistedSecret() string {
	const keyPath = `Software\Lux`
	k, err := registry.OpenKey(registry.CURRENT_USER, keyPath,
		registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		k, _, err = registry.CreateKey(registry.CURRENT_USER, keyPath,
			registry.ALL_ACCESS)
		if err != nil {
			return pseudoRandom()
		}
	}
	defer k.Close()

	s, _, err := k.GetStringValue("ApiSecret")
	if err != nil || s == "" {
		s = pseudoRandom()
		k.SetStringValue("ApiSecret", s)
	}
	return s
}

// pseudoRandom produces a UUID-shaped string without crypto/rand,
// which keeps CGO_ENABLED=0 clean.
func pseudoRandom() string {
	seed := time.Now().UnixNano()
	b := make([]byte, 16)
	for i := range b {
		seed = seed*6364136223846793005 + 1442695040888963407
		b[i] = byte(seed >> 33)
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// isAPIAlive checks if the core is responding (used by status polling).
func isAPIAlive() bool {
	c := &http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(fmt.Sprintf("http://localhost:%d/proxies", apiPort))
	if err != nil {
		return false
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return true
}
