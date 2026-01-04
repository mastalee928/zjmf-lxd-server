// @title LXD Web 管理平台
// @version 1.0.3
// @description LXD 容器管理 Web 平台，提供多节点管理、容器监控、NAT 配置等功能
// @termsOfService https://github.com/mastalee928/zjmf-lxd-server

// @contact.name mastalee928
// @contact.url https://github.com/mastalee928/zjmf-lxd-server
// @contact.email mastalee928@example.com

// @license.name MIT
// @license.url https://github.com/mastalee928/zjmf-lxd-server/blob/main/LICENSE

// @host localhost:3000
// @BasePath /

// @securityDefinitions.basic BasicAuth
// @in header
// @name Authorization
// @description 基于 Session 的认证

package main
import (
	"bufio"
	"fmt"
	"log"
	"os"
	"strings"
	"syscall"
	"lxdweb/config"
	"lxdweb/database"
	_ "lxdweb/docs"
	"lxdweb/handlers"
	"lxdweb/middleware"
	"lxdweb/models"
	"lxdweb/pkg/logger"
	"lxdweb/services"
	"lxdweb/utils"
	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
	swaggerFiles "github.com/swaggo/files"
	ginSwagger "github.com/swaggo/gin-swagger"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/term"
)
func main() {
	if len(os.Args) >= 2 && os.Args[1] == "admin" {
		handleAdminCommand()
		return
	}
	startWebServer()
}
func startWebServer() {
	if err := config.LoadConfig(); err != nil {
		log.Fatalf("[ERROR] 配置加载失败: %v", err)
	}
	
	zapLogger, err := utils.InitLogger(
		config.AppConfig.Logging.File,
		config.AppConfig.Logging.MaxSize,
		config.AppConfig.Logging.MaxBackups,
		config.AppConfig.Logging.MaxAge,
		config.AppConfig.Logging.Compress,
		config.AppConfig.Logging.Level,
		config.AppConfig.Logging.DevMode,
	)
	if err != nil {
		log.Fatalf("[ERROR] 日志系统初始化失败: %v", err)
	}
	
	logger.Init(zapLogger)
	log.Printf("[LOGGER] 日志系统初始化完成: 级别=%s, 文件=%s", config.AppConfig.Logging.Level, config.AppConfig.Logging.File)
	
	database.InitDB()
	database.CheckAdminExists()

	go services.StartContainerSyncService()
	go services.StartNATSyncService()
	go services.StartAutoSyncService()
	go services.StartNodeCacheService()
	
	gin.SetMode(config.AppConfig.Server.Mode)
	r := gin.Default()
	r.LoadHTMLGlob("templates/*")
	store := cookie.NewStore([]byte(config.AppConfig.Server.SessionSecret))
	r.Use(sessions.Sessions("lxdweb_session", store))
	
	r.GET("/swagger/*any", ginSwagger.WrapHandler(swaggerFiles.Handler))
	
	r.GET("/", handlers.LoginPage)
	r.GET("/login", handlers.LoginPage)
	r.POST("/login", handlers.Login)
	r.GET("/logout", handlers.Logout)
	r.GET("/api/captcha", handlers.GetCaptcha)
	auth := r.Group("/")
	auth.Use(middleware.AuthRequired())
	{
		auth.GET("/dashboard", handlers.DashboardPage)
		auth.GET("/nodes", handlers.NodesPage)
		auth.GET("/nodes/:id", handlers.NodeDetailPage)
		auth.GET("/nodes/:id/containers", handlers.NodeContainersPage)
		auth.GET("/nodes/:id/containers/:name", handlers.ContainerDetailPage)
		auth.GET("/nodes/:id/nat", handlers.NodeNATPage)
		auth.GET("/nodes/:id/ipv6", handlers.NodeIPv6Page)
		auth.GET("/nodes/:id/proxy", handlers.NodeProxyPage)
		auth.GET("/api/nodes", handlers.GetNodes)
		auth.GET("/api/nodes/:id", handlers.GetNode)
		auth.POST("/api/nodes", handlers.CreateNode)
		auth.PUT("/api/nodes/:id", handlers.UpdateNode)
		auth.DELETE("/api/nodes/:id", handlers.DeleteNode)
		auth.POST("/api/nodes/:id/test", handlers.TestNode)
		auth.POST("/api/nodes/:id/refresh", handlers.RefreshNodeCache)
		auth.GET("/api/nodes/export/all", handlers.ExportNodes)
		auth.POST("/api/nodes/import/batch", handlers.ImportNodes)
		auth.POST("/api/nodes/delete/batch", handlers.BatchDeleteNodes)
		
		// 容器API（保留API接口，但去掉全局页面入口）
		auth.GET("/api/containers", handlers.GetContainers)
		auth.GET("/api/containers/cache", handlers.GetContainersFromCache)
		auth.GET("/api/containers/:name", handlers.GetContainerDetail)
		auth.POST("/api/containers/:name/start", handlers.StartContainer)
		auth.POST("/api/containers/:name/stop", handlers.StopContainer)
		auth.POST("/api/containers/:name/restart", handlers.RestartContainer)
		auth.POST("/api/containers/:name/delete", handlers.DeleteContainer)
		auth.POST("/api/containers/:name/refresh", handlers.RefreshSingleContainer)
		auth.POST("/api/containers/:name/reinstall", handlers.ReinstallContainer)
		auth.POST("/api/containers/:name/password", handlers.ResetContainerPassword)
		auth.POST("/api/containers/:name/suspend", handlers.SuspendContainer)
		auth.POST("/api/containers/:name/unsuspend", handlers.UnsuspendContainer)
		auth.POST("/api/containers/:name/traffic/reset", handlers.ResetContainerTraffic)
		auth.POST("/api/containers/create", handlers.CreateContainer)
		// NAT API（保留API接口，但去掉全局页面入口）
		auth.GET("/api/nat", handlers.GetNATRules)
		auth.GET("/api/nat/:id", handlers.GetNATRule)
		auth.GET("/api/nat/check", handlers.CheckNATPort)
		auth.POST("/api/nat", handlers.CreateNATRule)
		auth.PUT("/api/nat/:id", handlers.UpdateNATRule)
		auth.DELETE("/api/nat/:id", handlers.DeleteNATRule)
		auth.POST("/api/nat/sync", handlers.SyncNATRules)
		auth.POST("/api/console/create-token", handlers.CreateConsoleToken)

		auth.POST("/api/sync/all", handlers.SyncAllNodes)
		auth.POST("/api/sync/node/:id", handlers.SyncNode)
		auth.GET("/api/sync/tasks", handlers.GetSyncTasks)
		auth.GET("/api/sync/status", handlers.GetSyncStatus)

		auth.POST("/api/nat-sync/all", handlers.SyncAllNAT)
		auth.POST("/api/nat-sync/node/:id", handlers.SyncNodeNAT)
		auth.GET("/api/nat-sync/tasks", handlers.GetNATSyncTasks)
		auth.GET("/api/nat-sync/status", handlers.GetNATSyncStatus)
		auth.GET("/api/nat/cache", handlers.GetNATRulesFromCache)

		// IPv6 API（保留API接口，但去掉全局页面入口）
		auth.GET("/api/ipv6", handlers.GetIPv6Bindings)
		auth.POST("/api/ipv6", handlers.CreateIPv6Binding)
		auth.DELETE("/api/ipv6/:id", handlers.DeleteIPv6Binding)
		auth.POST("/api/ipv6/sync", handlers.SyncIPv6Bindings)
		auth.GET("/api/ipv6/cache", handlers.GetIPv6BindingsFromCache)
		auth.POST("/api/ipv6-sync/all", handlers.SyncAllIPv6)
		auth.GET("/api/ipv6-sync/status", handlers.GetIPv6SyncStatus)
		auth.GET("/api/ipv6-sync/tasks", handlers.GetIPv6SyncTasks)

		// 反向代理 API（保留API接口，但去掉全局页面入口）
		auth.GET("/api/proxy-configs", handlers.GetProxyConfigs)
		auth.GET("/api/proxy/check", handlers.CheckProxyDomain)
		auth.POST("/api/proxy-configs", handlers.CreateProxyConfig)
		auth.DELETE("/api/proxy-configs/:id", handlers.DeleteProxyConfig)
		auth.POST("/api/proxy-configs/sync", handlers.SyncProxyConfigs)
		auth.GET("/api/proxy-configs/cache", handlers.GetProxyConfigsFromCache)
		auth.POST("/api/proxy-sync/all", handlers.SyncAllProxy)
		auth.GET("/api/proxy-sync/status", handlers.GetProxySyncStatus)
		auth.GET("/api/proxy-sync/tasks", handlers.GetProxySyncTasks)

		auth.GET("/api/auto-sync/status", handlers.GetAutoSyncStatus)
		auth.POST("/api/auto-sync/enable", handlers.EnableAutoSync)
		auth.POST("/api/auto-sync/disable", handlers.DisableAutoSync)
	}
	r.NoRoute(func(c *gin.Context) {
		path := c.Request.URL.Path
		if path == "/favicon.ico" {
			c.Status(204)
			return
		}
		c.Redirect(302, "/login")
	})
	addr := config.AppConfig.Server.Address
	
	if config.AppConfig.Server.EnableHTTPS {
		certFile := config.AppConfig.Server.CertFile
		keyFile := config.AppConfig.Server.KeyFile
		
		if err := utils.GenerateSelfSignedCert(certFile, keyFile); err != nil {
			log.Fatalf("[ERROR] 证书生成失败: %v", err)
		}
		
		log.Printf("[SERVER] HTTPS 服务器启动: https://%s", addr)
		if err := r.RunTLS(addr, certFile, keyFile); err != nil {
			log.Fatalf("[ERROR] HTTPS 服务器启动失败: %v", err)
		}
	} else {
		log.Printf("[WARN] HTTP 服务器启动 (不安全): http://%s", addr)
		if err := r.Run(addr); err != nil {
			log.Fatalf("[ERROR] HTTP 服务器启动失败: %v", err)
		}
	}
}
func handleAdminCommand() {
	if len(os.Args) < 3 {
		printAdminUsage()
		os.Exit(1)
	}
	if err := config.LoadConfig(); err != nil {
		log.Fatalf("配置加载失败: %v", err)
	}
	database.InitDB()
	command := os.Args[2]
	switch command {
	case "create":
		createAdmin()
	case "password":
		changePassword()
	case "list":
		listAdmins()
	case "delete":
		deleteAdmin()
	default:
		printAdminUsage()
		os.Exit(1)
	}
}
func printAdminUsage() {
	fmt.Println("LXD Web 管理员账号管理")
	fmt.Println("")
	fmt.Println("用法:")
	fmt.Println("  lxdweb admin create          创建新管理员")
	fmt.Println("  lxdweb admin password        修改管理员密码")
	fmt.Println("  lxdweb admin list            列出所有管理员")
	fmt.Println("  lxdweb admin delete          删除管理员")
	fmt.Println("")
	fmt.Println("示例:")
	fmt.Println("  lxdweb admin create")
	fmt.Println("  lxdweb admin password")
}
func createAdmin() {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print("输入用户名: ")
	username, _ := reader.ReadString('\n')
	username = strings.TrimSpace(username)
	if username == "" {
		log.Fatal("用户名不能为空")
	}
	var count int64
	database.DB.Model(&models.Admin{}).Where("username = ?", username).Count(&count)
	if count > 0 {
		log.Fatal("用户名已存在")
	}
	fmt.Print("输入邮箱 (可选): ")
	email, _ := reader.ReadString('\n')
	email = strings.TrimSpace(email)
	fmt.Print("输入密码: ")
	passwordBytes, err := term.ReadPassword(int(syscall.Stdin))
	if err != nil {
		log.Fatal("读取密码失败:", err)
	}
	fmt.Println()
	fmt.Print("确认密码: ")
	confirmBytes, err := term.ReadPassword(int(syscall.Stdin))
	if err != nil {
		log.Fatal("读取密码失败:", err)
	}
	fmt.Println()
	password := string(passwordBytes)
	confirm := string(confirmBytes)
	if password == "" {
		log.Fatal("密码不能为空")
	}
	if password != confirm {
		log.Fatal("两次输入的密码不一致")
	}
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		log.Fatal("密码加密失败:", err)
	}
	admin := models.Admin{
		Username: username,
		Password: string(hashedPassword),
		Email:    email,
	}
	if err := database.DB.Create(&admin).Error; err != nil {
		log.Fatal("创建管理员失败:", err)
	}
	fmt.Printf("\n[SUCCESS] 管理员 '%s' 创建成功\n", username)
}
func changePassword() {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print("输入用户名: ")
	username, _ := reader.ReadString('\n')
	username = strings.TrimSpace(username)
	if username == "" {
		log.Fatal("用户名不能为空")
	}
	var admin models.Admin
	if err := database.DB.Where("username = ?", username).First(&admin).Error; err != nil {
		log.Fatal("用户不存在")
	}
	fmt.Print("输入新密码: ")
	passwordBytes, err := term.ReadPassword(int(syscall.Stdin))
	if err != nil {
		log.Fatal("读取密码失败:", err)
	}
	fmt.Println()
	fmt.Print("确认新密码: ")
	confirmBytes, err := term.ReadPassword(int(syscall.Stdin))
	if err != nil {
		log.Fatal("读取密码失败:", err)
	}
	fmt.Println()
	password := string(passwordBytes)
	confirm := string(confirmBytes)
	if password == "" {
		log.Fatal("密码不能为空")
	}
	if password != confirm {
		log.Fatal("两次输入的密码不一致")
	}
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		log.Fatal("密码加密失败:", err)
	}
	admin.Password = string(hashedPassword)
	if err := database.DB.Save(&admin).Error; err != nil {
		log.Fatal("修改密码失败:", err)
	}
	fmt.Printf("\n[SUCCESS] 管理员 '%s' 密码修改成功\n", username)
}
func listAdmins() {
	var admins []models.Admin
	if err := database.DB.Find(&admins).Error; err != nil {
		log.Fatal("查询失败:", err)
	}
	if len(admins) == 0 {
		fmt.Println("暂无管理员账号")
		return
	}
	fmt.Println("\n管理员列表:")
	fmt.Println("────────────────────────────────────────")
	fmt.Printf("%-5s %-20s %-30s\n", "ID", "用户名", "邮箱")
	fmt.Println("────────────────────────────────────────")
	for _, admin := range admins {
		fmt.Printf("%-5d %-20s %-30s\n", admin.ID, admin.Username, admin.Email)
	}
	fmt.Println("────────────────────────────────────────")
	fmt.Printf("共 %d 个管理员\n\n", len(admins))
}
func deleteAdmin() {
	reader := bufio.NewReader(os.Stdin)
	fmt.Print("输入要删除的用户名: ")
	username, _ := reader.ReadString('\n')
	username = strings.TrimSpace(username)
	if username == "" {
		log.Fatal("用户名不能为空")
	}
	var admin models.Admin
	if err := database.DB.Where("username = ?", username).First(&admin).Error; err != nil {
		log.Fatal("用户不存在")
	}
	fmt.Printf("确定要删除管理员 '%s' 吗？(yes/no): ", username)
	confirm, _ := reader.ReadString('\n')
	confirm = strings.TrimSpace(strings.ToLower(confirm))
	if confirm != "yes" && confirm != "y" {
		fmt.Println("已取消")
		return
	}
	if err := database.DB.Delete(&admin).Error; err != nil {
		log.Fatal("删除失败:", err)
	}
	fmt.Printf("\n[SUCCESS] 管理员 '%s' 已删除\n", username)
}
