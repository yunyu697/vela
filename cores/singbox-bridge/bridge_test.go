package boxhubsingbox

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"testing"
	"time"
)

// freePort 探测一个空闲 TCP 端口（测试与 Dart 侧注入 controller 时的同款做法）。
func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// 最小可用配置：mixed 入站 + direct 出站 + selector 分组（验证分组链路）。
func testConfig(mixedPort int) string {
	return fmt.Sprintf(`{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": %d
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "selector", "tag": "手动选择", "outbounds": ["direct"]}
  ],
  "route": {
    "rules": [
      {"action": "sniff"}
    ],
    "final": "手动选择"
  }
}`, mixedPort)
}

func TestStartStop(t *testing.T) {
	mixedPort := freePort(t)
	apiPort := freePort(t)
	origin, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer origin.Close()
	go func() {
		for {
			c, err := origin.Accept()
			if err != nil {
				return
			}
			// 延迟响应：保持连接存活，便于观察连接表
			go func() {
				time.Sleep(500 * time.Millisecond)
				io.WriteString(c, "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nhello-boxhub")
				c.Close()
			}()
		}
	}()

	workDir := t.TempDir()
	apiAddr := fmt.Sprintf("127.0.0.1:%d", apiPort)

	if err := StartConfig(testConfig(mixedPort), workDir, apiAddr, "test-secret"); err != nil {
		t.Fatalf("StartConfig: %v (LastError=%s)", err, LastError())
	}
	defer StopConfig()
	if !IsRunning() {
		t.Fatal("IsRunning should be true")
	}

	// ---- 1. 数据面：经 mixed 代理访问本地源站 ----
	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			Proxy: http.ProxyURL(parseURL(fmt.Sprintf("http://127.0.0.1:%d", mixedPort))),
		},
	}
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/", origin.Addr().(*net.TCPAddr).Port))
	if err != nil {
		t.Fatalf("proxy request: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "hello-boxhub" {
		t.Fatalf("unexpected body: %q", string(body))
	}
	t.Log("data plane OK via mixed proxy")

	// ---- 2. 控制面：clash API（TCP + Bearer secret）----
	req, _ := http.NewRequest("GET", fmt.Sprintf("http://%s/version", apiAddr), nil)
	req.Header.Set("Authorization", "Bearer test-secret")
	resp2, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		t.Fatalf("clash api: %v", err)
	}
	b2, _ := io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("clash api status: %d body=%s", resp2.StatusCode, b2)
	}
	t.Logf("clash api /version -> %s", b2)

	// 无 secret 应被拒绝
	req3, _ := http.NewRequest("GET", fmt.Sprintf("http://%s/version", apiAddr), nil)
	resp3, _ := (&http.Client{Timeout: 5 * time.Second}).Do(req3)
	if resp3 != nil {
		resp3.Body.Close()
		if resp3.StatusCode == 200 {
			t.Fatal("unauthorized request should not succeed")
		}
	}

	// ---- 3. 停止：幂等 + 端口关闭 ----
	if err := StopConfig(); err != nil {
		t.Fatalf("StopConfig: %v", err)
	}
	if err := StopConfig(); err != nil {
		t.Fatalf("StopConfig twice: %v", err)
	}
	if IsRunning() {
		t.Fatal("IsRunning should be false after stop")
	}
	time.Sleep(300 * time.Millisecond)
	if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", mixedPort), time.Second); err == nil {
		c.Close()
		t.Fatal("mixed port should be closed after stop")
	}
	if c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", apiPort), time.Second); err == nil {
		c.Close()
		t.Fatal("api port should be closed after stop")
	}
	t.Log("stop OK, ports closed")
}

func TestRestart(t *testing.T) {
	mixedPort := freePort(t)
	apiPort := freePort(t)
	workDir := t.TempDir()
	cfg := testConfig(mixedPort)
	apiAddr := fmt.Sprintf("127.0.0.1:%d", apiPort)

	if err := StartConfig(cfg, workDir, apiAddr, "s"); err != nil {
		t.Fatalf("start 1: %v", err)
	}
	if err := RestartConfig(cfg, workDir, apiAddr, "s"); err != nil {
		t.Fatalf("restart: %v (LastError=%s)", err, LastError())
	}
	if !IsRunning() {
		t.Fatal("should be running after restart")
	}
	if err := StopConfig(); err != nil {
		t.Fatalf("stop: %v", err)
	}
}

// parseURL 简化 error 处理的 helper。
func parseURL(raw string) *url.URL {
	u, err := url.Parse(raw)
	if err != nil {
		panic(err)
	}
	return u
}

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}
