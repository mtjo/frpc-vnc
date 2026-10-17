// frpc 移动端桥接模块。
//
// 封装 frp 官方 client 库，通过 gomobile bind 编译为
// Android AAR / iOS xcframework，由 Flutter platform channel 调用。
//
// 导出接口（gomobile 生成对应绑定）：
//   Start(profileID, toml string) error
//   Stop(profileID string) error
//   StopAll() error
//   IsRunning(profileID string) bool
//   SetEventCallback(cb EventCallback)  // cb(profileID, eventType, payload string)

package frpcbridge

import (
	"context"
	"fmt"
	"sync"

	frpc "github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	v1 "github.com/fatedier/frp/pkg/config/v1"
)

// EventCallback: profileID, type("state"/"log"/"error"), payload
type EventCallback func(profileID string, eventType string, payload string)

var (
	mu       sync.Mutex
	clients  = map[string]*frpc.Service{}
	cancels  = map[string]context.CancelFunc{}
	callback EventCallback
)

// SetEventCallback 注册事件回调（gomobile 绑定中可直接传入函数对象）。
func SetEventCallback(cb EventCallback) {
	mu.Lock()
	defer mu.Unlock()
	callback = cb
}

func emit(profileID, typ, payload string) {
	mu.Lock()
	cb := callback
	mu.Unlock()
	if cb != nil {
		go cb(profileID, typ, payload)
	}
}

// Start 以 TOML 配置启动一个 frpc 实例。
func Start(profileID string, toml string) error {
	mu.Lock()
	if _, ok := clients[profileID]; ok {
		mu.Unlock()
		return fmt.Errorf("profile %s already running", profileID)
	}
	mu.Unlock()

	var cfg v1.ClientConfig
	if err := config.LoadConfigure([]byte(toml), &cfg, false); err != nil {
		emit(profileID, "error", "解析配置失败: "+err.Error())
		return fmt.Errorf("parse config: %w", err)
	}

	proxies := make([]v1.ProxyConfigurer, 0, len(cfg.Proxies))
	for i := range cfg.Proxies {
		proxies = append(proxies, cfg.Proxies[i].ProxyConfigurer)
	}
	visitors := make([]v1.VisitorConfigurer, 0, len(cfg.Visitors))
	for i := range cfg.Visitors {
		visitors = append(visitors, cfg.Visitors[i].VisitorConfigurer)
	}

	sv, err := frpc.NewService(frpc.ServiceOptions{
		Common:      &cfg.ClientCommonConfig,
		ProxyCfgs:   proxies,
		VisitorCfgs: visitors,
	})
	if err != nil {
		emit(profileID, "error", "创建服务失败: "+err.Error())
		return fmt.Errorf("create service: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	mu.Lock()
	clients[profileID] = sv
	cancels[profileID] = cancel
	mu.Unlock()

	emit(profileID, "state", "starting")

	go func() {
		defer func() {
			mu.Lock()
			delete(clients, profileID)
			delete(cancels, profileID)
			mu.Unlock()
			emit(profileID, "state", "stopped")
		}()
		// Run 阻塞至连接关闭。
		if err := sv.Run(ctx); err != nil {
			emit(profileID, "error", err.Error())
		}
	}()

	return nil
}

// Stop 停止指定实例。
func Stop(profileID string) error {
	mu.Lock()
	sv, ok := clients[profileID]
	cancel := cancels[profileID]
	mu.Unlock()
	if !ok {
		return nil
	}
	if cancel != nil {
		cancel()
	}
	sv.Close()
	mu.Lock()
	delete(clients, profileID)
	delete(cancels, profileID)
	mu.Unlock()
	emit(profileID, "state", "stopped")
	return nil
}

// StopAll 停止全部实例。
func StopAll() error {
	mu.Lock()
	ids := make([]string, 0, len(clients))
	for id := range clients {
		ids = append(ids, id)
	}
	mu.Unlock()
	for _, id := range ids {
		_ = Stop(id)
	}
	return nil
}

// IsRunning 查询实例是否运行中。
func IsRunning(profileID string) bool {
	mu.Lock()
	defer mu.Unlock()
	_, ok := clients[profileID]
	return ok
}

// Version 返回桥接版本标识。
func Version() string {
	return "frpc-bridge-1.0.0"
}
