package boxhubmihomo

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func unixHTTPClient(socket string) *http.Client {
	return &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return net.Dial("unix", socket)
			},
		},
	}
}

func TestStartStop(t *testing.T) {
	dir := t.TempDir()
	socket := filepath.Join(dir, "mihomo.sock")
	_ = os.Remove(socket)

	configYAML := `
mixed-port: 17890
mode: rule
log-level: info
dns:
  enable: false
`
	if err := StartConfig(configYAML, dir, socket, ""); err != nil {
		t.Fatalf("StartConfig: %v", err)
	}
	if !IsRunning() {
		t.Fatal("should be running")
	}

	// mixed 端口已监听
	conn, err := net.DialTimeout("tcp", "127.0.0.1:17890", time.Second)
	if err != nil {
		t.Fatalf("mixed port not listening: %v", err)
	}
	_ = conn.Close()

	// unix socket 上的 clash API 可用
	resp, err := unixHTTPClient(socket).Get("http://localhost/version")
	if err != nil {
		t.Fatalf("controller via unix socket: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("controller status: %d", resp.StatusCode)
	}
	var version map[string]Object
	if err := json.NewDecoder(resp.Body).Decode(&version); err != nil {
		t.Fatalf("decode version: %v", err)
	}
	t.Logf("controller version response: %v", version)

	// 停止后端口关闭
	if err := StopConfig(); err != nil {
		t.Fatalf("StopConfig: %v", err)
	}
	if IsRunning() {
		t.Fatal("should be stopped")
	}
	time.Sleep(200 * time.Millisecond)
	if c, err := net.DialTimeout("tcp", "127.0.0.1:17890", 500*time.Millisecond); err == nil {
		_ = c.Close()
		t.Fatal("mixed port still open after stop")
	}

	// 重复停止应幂等
	if err := StopConfig(); err != nil {
		t.Fatalf("second StopConfig: %v", err)
	}
}

// Object 兼容任意 JSON 对象。
type Object = interface{}
