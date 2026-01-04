package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"

	"lxdimages/tools"
)

const (
	Version   = "1.0.1"
	Developer = "mastalee928"
	RepoURL   = "https://github.com/mastalee928/zjmf-lxd-server"
)

func main() {
	if len(os.Args) < 2 {
		showHelp()
		os.Exit(1)
	}

	if os.Args[1] == "-h" || os.Args[1] == "--help" {
		showHelp()
		os.Exit(0)
	}

	if os.Args[1] == "-v" || os.Args[1] == "--version" {
		fmt.Printf("LXD 镜像构建工具 v%s\n", Version)
		fmt.Printf("开发者: %s\n", Developer)
		fmt.Printf("项目地址: %s\n", RepoURL)
		os.Exit(0)
	}

	if len(os.Args) < 3 {
		log.Fatal("参数不足，需要: <distro> <version> [-add <tool>] [-name <image_name>] [-export]")
	}

	distro := os.Args[1]
	version := os.Args[2]
	
	if err := tools.ValidateDistroVersion(distro, version); err != nil {
		log.Fatalf("错误: %v", err)
	}
	
	arch := getSystemArch()
	
	if distro == "amazonlinux" && arch == "arm64" {
		log.Fatal("错误: Amazon Linux 2023 不支持 arm64 架构，请使用 amd64 系统")
	}

	var toolsList []string
	customName := ""
	exportImage := false
	
	for i := 3; i < len(os.Args); i++ {
		switch os.Args[i] {
		case "-add":
			if i+1 >= len(os.Args) {
				log.Fatal("-add 参数后需要指定工具名称")
			}
			toolsStr := os.Args[i+1]
			toolsList = strings.Split(toolsStr, ",")
			for j := range toolsList {
				toolsList[j] = strings.TrimSpace(toolsList[j])
			}
			i++
		case "-name":
			if i+1 >= len(os.Args) {
				log.Fatal("-name 参数后需要指定镜像名称")
			}
			customName = os.Args[i+1]
			i++
		case "-export":
			exportImage = true
		}
	}

	fmt.Printf(">> LXD 镜像构建工具 v%s by %s\n", Version, Developer)
	fmt.Printf(">> 开始构建 %s %s (%s)\n", distro, version, arch)
	
	if len(toolsList) == 0 {
		fmt.Printf(">> 构建基础镜像...\n")
		if err := buildBasicImage(distro, version, arch, customName, exportImage); err != nil {
			log.Fatalf("ERROR: 构建失败: %v", err)
		}
		fmt.Printf(">> 基础镜像构建完成\n")
	} else {
		fmt.Printf(">> 构建带工具的镜像 [%s]...\n", strings.Join(toolsList, ", "))
		if err := buildImageWithTools(distro, version, arch, toolsList, customName, exportImage); err != nil {
			log.Fatalf("ERROR: 构建失败: %v", err)
		}
		fmt.Printf(">> 镜像构建完成\n")
	}
}

func checkURLExists(url string) bool {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Head(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func getLatestDirectory(baseURL string) (string, error) {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(baseURL)
	if err != nil {
		return "", fmt.Errorf("获取目录页面失败: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("目录页面不可用，状态码: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("读取响应失败: %v", err)
	}

	content := string(body)

	pattern := `href="([0-9]{8}_[0-9]{2}%3A[0-9]{2}/)"`
	re := regexp.MustCompile(pattern)
	matches := re.FindAllStringSubmatch(content, -1)

	if len(matches) == 0 {
		return "", fmt.Errorf("未找到任何构建目录")
	}

	var directories []string
	for _, match := range matches {
		if len(match) > 1 {
			dir := strings.Replace(match[1], "%3A", ":", -1)
			directories = append(directories, dir)
		}
	}

	sort.Sort(sort.Reverse(sort.StringSlice(directories)))

	if len(directories) == 0 {
		return "", fmt.Errorf("未找到有效的构建目录")
	}

	return directories[0], nil
}
func forceStopContainer(containerName string) error {
	fmt.Printf("     强制停止容器...\n")
	

	stopCmd := exec.Command("lxc", "stop", containerName, "--timeout", "10")
	stopCmd.Stdout = nil
	stopCmd.Stderr = nil
	if err := stopCmd.Run(); err == nil {
		return nil
	}
	

	forceStopCmd := exec.Command("lxc", "stop", containerName, "--force")
	forceStopCmd.Stdout = nil
	forceStopCmd.Stderr = nil
	forceStopCmd.Run()
	

	time.Sleep(3 * time.Second)
	

	statusCmd := exec.Command("lxc", "info", containerName)
	statusCmd.Stdout = nil
	statusCmd.Stderr = nil
	if err := statusCmd.Run(); err != nil {

		return nil
	}
	
	return nil
}
func cleanLXCName(name string) string {

	cleaned := strings.ReplaceAll(name, ".", "")
	cleaned = strings.ReplaceAll(cleaned, "_", "-")
	cleaned = strings.ReplaceAll(cleaned, " ", "-")

	cleaned = strings.Trim(cleaned, "-")

	for strings.Contains(cleaned, "--") {
		cleaned = strings.ReplaceAll(cleaned, "--", "-")
	}
	return cleaned
}
func getSystemArch() string {
	arch := runtime.GOARCH
	switch arch {
	case "amd64":
		return "amd64"
	case "arm64":
		return "arm64"
	default:
		log.Fatalf("不支持的系统架构: %s，只支持 amd64 和 arm64", arch)
		return ""
	}
}

func buildBasicImage(distro, version, arch, customName string, exportImage bool) error {

	fmt.Printf("   下载镜像文件...\n")
	if err := downloadImageFiles(distro, version, arch); err != nil {
		cleanupFiles()
		return fmt.Errorf("获取镜像文件失败: %v", err)
	}
	fmt.Printf("   构建镜像...\n")
	var imageName string
	if customName != "" {
		imageName = cleanLXCName(customName)
	} else {
		imageName = cleanLXCName(fmt.Sprintf("%s-%s-%s", distro, version, arch))
	}
	
	if err := buildLXCImage(imageName); err != nil {
		cleanupFiles()
		cleanupResources(imageName, "", "")
		return fmt.Errorf("构建基础镜像失败: %v", err)
	}
	if exportImage {
		fmt.Printf("   导出镜像...\n")
		if err := publishAndExportImage("", imageName); err != nil {
			cleanupFiles()
			cleanupResources(imageName, "", "")
			return fmt.Errorf("导出镜像失败: %v", err)
		}
		fmt.Printf("   文件: %s.tar.gz\n", imageName)
	}
	fmt.Printf("   清理临时文件...\n")
	cleanupFiles()

	if exportImage {
		fmt.Printf("   镜像: %s (已导出)\n", imageName)
	} else {
		fmt.Printf("   镜像: %s\n", imageName)
	}
	return nil
}

func buildImageWithTools(distro, version, arch string, toolsList []string, customName string, exportImage bool) error {

	fmt.Printf("   下载镜像文件...\n")
	if err := downloadImageFiles(distro, version, arch); err != nil {
		cleanupFiles()
		return fmt.Errorf("获取镜像文件失败: %v", err)
	}
	fmt.Printf("   构建基础镜像...\n")
	baseName := cleanLXCName(fmt.Sprintf("%s-%s-%s-base", distro, version, arch))
	if err := buildLXCImage(baseName); err != nil {
		cleanupFiles()
		cleanupResources(baseName, "", "")
		return fmt.Errorf("构建基础镜像失败: %v", err)
	}
	fmt.Printf("   启动容器...\n")

	containerName := cleanLXCName(fmt.Sprintf("%s-config", baseName))
	if err := launchLXCContainer(baseName, containerName); err != nil {
		cleanupFiles()
		cleanupResources(baseName, containerName, "")
		return fmt.Errorf("运行容器失败: %v", err)
	}
	
	for _, tool := range toolsList {
		fmt.Printf("   配置 %s...\n", tool)
		if err := configureTool(containerName, distro, version, tool); err != nil {
			cleanupFiles()
			cleanupResources(baseName, containerName, "")
			return fmt.Errorf("配置%s工具失败: %v", tool, err)
		}
	}
	
	fmt.Printf("   执行最终清理...\n")
	if err := finalCleanup(containerName, distro); err != nil {
		fmt.Printf("     警告: 清理过程出现错误: %v\n", err)
	}
	
	fmt.Printf("   构建最终镜像...\n")
	var finalImageName string
	if customName != "" {
		finalImageName = cleanLXCName(customName)
	} else {
		toolsStr := strings.Join(toolsList, "-")
		finalImageName = cleanLXCName(fmt.Sprintf("%s-%s-%s-%s", distro, version, arch, toolsStr))
	}
	
	if exportImage {

		if err := publishAndExportImage(containerName, finalImageName); err != nil {
			cleanupFiles()
			cleanupResources(baseName, containerName, finalImageName)
			return fmt.Errorf("构建新镜像失败: %v", err)
		}
		fmt.Printf("   文件: %s.tar.gz\n", finalImageName)
	} else {

		if err := publishToLXC(containerName, finalImageName); err != nil {
			cleanupFiles()
			cleanupResources(baseName, containerName, finalImageName)
			return fmt.Errorf("构建新镜像失败: %v", err)
		}
	}
	fmt.Printf("   清理资源...\n")
	cleanupResources(baseName, containerName, "")
	cleanupFiles()

	if exportImage {
		fmt.Printf("   镜像: %s (已导出)\n", finalImageName)
	} else {
		fmt.Printf("   镜像: %s\n", finalImageName)
	}
	return nil
}
func downloadImageFiles(distro, version, arch string) error {
	baseURL := fmt.Sprintf("https://images.linuxcontainers.org/images/%s/%s/%s/default/", distro, version, arch)

	latestDir, err := getLatestDirectory(baseURL)
	if err != nil {
		return fmt.Errorf("获取最新目录失败: %v", err)
	}

	rootfsURL := baseURL + latestDir + "rootfs.tar.xz"
	metaURL := baseURL + latestDir + "meta.tar.xz"
	if !checkURLExists(rootfsURL) {
		return fmt.Errorf("rootfs文件不存在: %s", rootfsURL)
	}
	if !checkURLExists(metaURL) {
		return fmt.Errorf("meta文件不存在: %s", metaURL)
	}
	if err := downloadFile(rootfsURL, "rootfs.tar.xz"); err != nil {
		return fmt.Errorf("下载rootfs文件失败: %v", err)
	}
	if err := downloadFile(metaURL, "meta.tar.xz"); err != nil {
		return fmt.Errorf("下载meta文件失败: %v", err)
	}

	return nil
}
func buildLXCImage(imageName string) error {

	parts := strings.Split(imageName, "-")
	if len(parts) < 3 {
		return fmt.Errorf("镜像名称格式错误: %s", imageName)
	}
	distro := parts[0]

	version := strings.Join(parts[1:len(parts)-1], "-")
	arch := parts[len(parts)-1]
	

	if strings.HasSuffix(imageName, "-base") {

		nameWithoutBase := strings.TrimSuffix(imageName, "-base")
		parts = strings.Split(nameWithoutBase, "-")
		if len(parts) >= 3 {
			distro = parts[0]
			version = strings.Join(parts[1:len(parts)-1], "-")
			arch = parts[len(parts)-1]
		}
	}
	
	fmt.Printf("     解析参数: distro=%s, version=%s, arch=%s\n", distro, version, arch)
	

	fmt.Printf("     生成metadata.yaml...\n")
	if err := generateMetadataYAML(distro, version, arch); err != nil {
		return fmt.Errorf("生成metadata.yaml失败: %v", err)
	}
	fmt.Printf("     打包metadata文件...\n")
	if err := createMetaTarXZ(); err != nil {
		return fmt.Errorf("打包metadata.yaml失败: %v", err)
	}
	fmt.Printf("     导入到LXC...\n")
	if err := importLXCImage("meta-fixed.tar.xz", "rootfs.tar.xz", imageName); err != nil {
		return fmt.Errorf("导入LXC镜像失败: %v", err)
	}

	return nil
}
func publishToLXC(containerName, imageName string) error {

	deleteCmd := exec.Command("lxc", "image", "delete", imageName)
	deleteCmd.Stdout = nil
	deleteCmd.Stderr = nil
	deleteCmd.Run()
	if err := forceStopContainer(containerName); err != nil {
		return fmt.Errorf("停止容器失败: %v", err)
	}
	fmt.Printf("     发布镜像...\n")
	publishCmd := exec.Command("lxc", "publish", containerName, "--alias", imageName)
	

	var stderr strings.Builder
	publishCmd.Stderr = &stderr
	publishCmd.Stdout = nil
	
	if err := publishCmd.Run(); err != nil {
		errorMsg := stderr.String()
		if errorMsg != "" {
			return fmt.Errorf("发布镜像失败: %v, 错误详情: %s", err, errorMsg)
		}
		return fmt.Errorf("发布镜像失败: %v", err)
	}

	return nil
}
func publishAndExportImage(containerName, imageName string) error {

	if containerName != "" {

		deleteCmd := exec.Command("lxc", "image", "delete", imageName)
		deleteCmd.Stdout = nil
		deleteCmd.Stderr = nil
		deleteCmd.Run()

		if err := forceStopContainer(containerName); err != nil {
			return fmt.Errorf("停止容器失败: %v", err)
		}

		publishCmd := exec.Command("lxc", "publish", containerName, "--alias", imageName)
		
		var stderr strings.Builder
		publishCmd.Stderr = &stderr
		publishCmd.Stdout = nil
		
		if err := publishCmd.Run(); err != nil {
			errorMsg := stderr.String()
			if errorMsg != "" {
				return fmt.Errorf("发布镜像失败: %v, 错误详情: %s", err, errorMsg)
			}
			return fmt.Errorf("发布镜像失败: %v", err)
		}
	}
	exportCmd := exec.Command("lxc", "image", "export", imageName, imageName)
	
	var stderr strings.Builder
	exportCmd.Stderr = &stderr
	exportCmd.Stdout = nil
	
	if err := exportCmd.Run(); err != nil {
		errorMsg := stderr.String()
		if errorMsg != "" {
			return fmt.Errorf("导出镜像文件失败: %v, 错误详情: %s", err, errorMsg)
		}
		return fmt.Errorf("导出镜像文件失败: %v", err)
	}

	actualExportFileName := imageName + ".tar.gz"
	if _, err := os.Stat(actualExportFileName); err != nil {
		return fmt.Errorf("导出文件不存在: %v", err)
	}

	return nil
}

func cleanupResources(baseImageName, containerName, finalImageName string) {
	if containerName != "" {
		cmd := exec.Command("lxc", "delete", "-f", containerName)
		cmd.Stdout = nil
		cmd.Stderr = nil
		cmd.Run() 
	}

	if baseImageName != "" {
		cmd := exec.Command("lxc", "image", "delete", baseImageName)
		cmd.Stdout = nil
		cmd.Stderr = nil
		cmd.Run() 
	}

	if finalImageName != "" {
		cmd := exec.Command("lxc", "image", "delete", finalImageName)
		cmd.Stdout = nil
		cmd.Stderr = nil
		cmd.Run()
	}
}
func downloadFile(url, filename string) error {
	client := &http.Client{Timeout: 30 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("请求失败: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("下载失败，状态码: %d", resp.StatusCode)
	}

	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("创建文件失败: %v", err)
	}
	defer file.Close()

	contentLength := resp.ContentLength
	var downloaded int64
	buffer := make([]byte, 32*1024)

	fmt.Printf("     %s", filename)
	if contentLength > 0 {
		fmt.Printf(" (%.1f MB)", float64(contentLength)/1024/1024)
	}
	fmt.Printf(" ... ")

	lastPercent := -1
	for {
		n, err := resp.Body.Read(buffer)
		if n > 0 {
			written, err := file.Write(buffer[:n])
			if err != nil {
				return fmt.Errorf("写入文件失败: %v", err)
			}
			downloaded += int64(written)

			if contentLength > 0 {
				percent := int(float64(downloaded) / float64(contentLength) * 100)
				if percent != lastPercent && percent%10 == 0 {
					fmt.Printf("%d%% ", percent)
					lastPercent = percent
				}
			}
		}

		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("读取响应失败: %v", err)
		}
	}

	fmt.Printf("OK (%.1f MB)\n", float64(downloaded)/1024/1024)
	
	return nil
}

func importLXCImage(metaFile, rootfsFile, imageName string) error {
	deleteCmd := exec.Command("lxc", "image", "delete", imageName)
	deleteCmd.Stdout = nil
	deleteCmd.Stderr = nil
	deleteCmd.Run() 

	cmd := exec.Command("lxc", "image", "import", metaFile, rootfsFile, "--alias", imageName)
	
	var stderr strings.Builder
	cmd.Stderr = &stderr
	cmd.Stdout = nil

	if err := cmd.Run(); err != nil {
		errorMsg := stderr.String()
		if errorMsg != "" {
			return fmt.Errorf("镜像导入失败: %v, 错误详情: %s", err, errorMsg)
		}
		return fmt.Errorf("镜像导入失败: %v", err)
	}

	return nil
}

func generateMetadataYAML(distro, version, arch string) error {
	creationDate := time.Now().Unix()
	
	lxdArch := arch
	if arch == "amd64" {
		lxdArch = "x86_64"
	} else if arch == "arm64" {
		lxdArch = "aarch64"
	}

	description := fmt.Sprintf("%s %s %s", strings.Title(distro), version, strings.ToUpper(arch))

	metadataContent := fmt.Sprintf(`architecture: %s
creation_date: %d
properties:
  architecture: %s
  description: "%s"
  os: %s
  release: "%s"
  variant: default
templates: {}
`, lxdArch, creationDate, lxdArch, description, distro, version)

	err := os.WriteFile("metadata.yaml", []byte(metadataContent), 0644)
	if err != nil {
		return fmt.Errorf("写入metadata.yaml失败: %v", err)
	}

	return nil
}

func createMetaTarXZ() error {
	cmd := exec.Command("tar", "-cJf", "meta-fixed.tar.xz", "metadata.yaml")
	
	var stderr strings.Builder
	cmd.Stderr = &stderr
	cmd.Stdout = nil

	if err := cmd.Run(); err != nil {
		errorMsg := stderr.String()
		if errorMsg != "" {
			return fmt.Errorf("打包metadata.yaml失败: %v, 错误详情: %s", err, errorMsg)
		}
		return fmt.Errorf("打包metadata.yaml失败: %v", err)
	}

	return nil
}

func launchLXCContainer(imageName, containerName string) error {
	deleteCmd := exec.Command("lxc", "delete", "-f", containerName)
	deleteCmd.Stdout = nil
	deleteCmd.Stderr = nil
	deleteCmd.Run()

	cmd := exec.Command("lxc", "launch", imageName, containerName)
	
	var stderr strings.Builder
	cmd.Stderr = &stderr
	cmd.Stdout = nil

	if err := cmd.Run(); err != nil {
		errorMsg := stderr.String()
		if errorMsg != "" {
			return fmt.Errorf("容器启动失败: %v, 错误详情: %s", err, errorMsg)
		}
		return fmt.Errorf("容器启动失败: %v", err)
	}

	return nil
}

func configureTool(containerName, distro, version, tool string) error {
	switch tool {
	case "ssh":
		return tools.ConfigureSSH(containerName, distro, version)
	case "docker":
		return tools.ConfigureDocker(containerName, distro, version)
	case "nodejs":
		return tools.ConfigureNodejs(containerName, distro, version)
	case "python":
		return tools.ConfigurePython(containerName, distro, version)
	case "nginx":
		return tools.ConfigureNginx(containerName, distro, version)
	case "mysql":
		return tools.ConfigureMysql(containerName, distro, version)
	case "postgresql":
		return tools.ConfigurePostgresql(containerName, distro, version)
	case "java":
		return tools.ConfigureJava(containerName, distro, version)
	case "golang":
		return tools.ConfigureGolang(containerName, distro, version)
	case "php":
		return tools.ConfigurePhp(containerName, distro, version)
	case "redis":
		return tools.ConfigureRedis(containerName, distro, version)
	case "mongodb":
		return tools.ConfigureMongodb(containerName, distro, version)
	case "apache":
		return tools.ConfigureApache(containerName, distro, version)
	case "git":
		return tools.ConfigureGit(containerName, distro, version)
	default:
		return fmt.Errorf("不支持的工具: %s", tool)
	}
}


func cleanupFiles() error {
	filesToClean := []string{
		"rootfs.tar.xz",
		"meta.tar.xz",
		"metadata.yaml",
		"meta-fixed.tar.xz",
	}

	for _, file := range filesToClean {
		if _, err := os.Stat(file); err == nil {
			os.Remove(file)
		}
	}

	return nil
}

func finalCleanup(containerName, distro string) error {
	cleanupCommands := []string{
		"rm -rf /tmp/* /var/tmp/* /root/.cache",
		"rm -f /root/.bash_history /root/.wget-hsts",
		"find /var/log -type f -exec truncate -s 0 {} \\;",
		"find /root -name '*.log' -delete",
	}

	switch distro {
	case "ubuntu", "debian":
		cleanupCommands = append(cleanupCommands,
			"apt-get autoremove -y",
			"apt-get autoclean",
			"apt-get clean",
			"rm -rf /var/lib/apt/lists/*",
			"rm -rf /var/cache/apt/*",
		)
	case "centos", "fedora", "almalinux", "rockylinux":
		cleanupCommands = append(cleanupCommands,
			"dnf autoremove -y",
			"dnf clean all",
			"rm -rf /var/cache/dnf/*",
		)
	case "oracle", "amazonlinux":
		cleanupCommands = append(cleanupCommands,
			"yum autoremove -y",
			"yum clean all",
			"rm -rf /var/cache/yum/*",
		)
	case "alpine":
		cleanupCommands = append(cleanupCommands,
			"rm -rf /var/cache/apk/*",
			"rm -rf /etc/apk/cache/*",
		)
	case "opensuse":
		cleanupCommands = append(cleanupCommands,
			"zypper clean -a",
			"rm -rf /var/cache/zypp/*",
		)
	}

	cleanupCommands = append(cleanupCommands,
		"history -c",
		"rm -f /root/.bash_history",
		"sync",
	)

	for _, cmdStr := range cleanupCommands {
		cmd := exec.Command("lxc", "exec", containerName, "--", "sh", "-c", cmdStr)
		cmd.Stdout = nil
		cmd.Stderr = nil
		cmd.Run()
	}

	return nil
}

func showHelp() {
	fmt.Println("┌───────────────────────────────────────────────────────────────┐")
	fmt.Printf("│  LXD 镜像构建工具 v%-39s│\n", Version)
	fmt.Printf("│  开发者: %-49s│\n", Developer)
	fmt.Printf("│  项目地址: %-47s│\n", RepoURL)
	fmt.Println("└───────────────────────────────────────────────────────────────┘")
	fmt.Println()
	fmt.Println("用法:")
	fmt.Println("  lxdimages <distro> <version> [选项]")
	fmt.Println()
	fmt.Println("选项:")
	fmt.Println("  -add <tool>       添加工具集(可用逗号分隔多个，如: ssh,mysql,nodejs)")
	fmt.Println("                    支持的工具:")
	fmt.Println("                      ssh        - SSH 服务器")
	fmt.Println("                      docker     - Docker 容器引擎(系统源)")
	fmt.Println("                      nodejs     - Node.js(系统源)")
	fmt.Println("                      python     - Python3(系统源)")
	fmt.Println("                      java       - OpenJDK(系统源)")
	fmt.Println("                      golang     - Go 语言(系统源)")
	fmt.Println("                      php        - PHP + Composer(系统源)")
	fmt.Println("                      nginx      - Nginx Web 服务器")
	fmt.Println("                      apache     - Apache HTTP 服务器")
	fmt.Println("                      mysql      - MySQL 数据库(系统源)")
	fmt.Println("                      postgresql - PostgreSQL 数据库(系统源)")
	fmt.Println("                      redis      - Redis 缓存服务器")
	fmt.Println("                      mongodb    - MongoDB 数据库(系统源)")
	fmt.Println("                      git        - Git 版本控制工具")
	fmt.Println("  -name <name>      自定义镜像名称")
	fmt.Println("  -export           导出镜像为 tar.gz 文件")
	fmt.Println("  -h, --help        显示帮助信息")
	fmt.Println("  -v, --version     显示版本信息")
	fmt.Println()
	fmt.Println("支持的发行版和版本:")
	
	distros := []string{"ubuntu", "debian", "centos", "fedora", "almalinux", "rockylinux", "oracle", "opensuse", "alpine", "amazonlinux"}
	for _, distro := range distros {
		if versions, ok := tools.SupportedDistros[distro]; ok {
			versionStr := strings.Join(versions, ", ")
			if distro == "amazonlinux" {
				versionStr += " (仅amd64)"
			}
			fmt.Printf("  %-15s %s\n", distro+":", versionStr)
		}
	}
	
	fmt.Println()
	fmt.Println("示例:")
	fmt.Println("  # 基础镜像")
	fmt.Println("  lxdimages ubuntu jammy")
	fmt.Println()
	fmt.Println("  # 单个工具")
	fmt.Println("  lxdimages ubuntu noble -add ssh")
	fmt.Println("  lxdimages debian bookworm -add nodejs")
	fmt.Println()
	fmt.Println("  # 多个工具组合")
	fmt.Println("  lxdimages ubuntu jammy -add ssh,mysql,nginx")
	fmt.Println("  lxdimages debian bookworm -add ssh,nodejs,redis")
	fmt.Println("  lxdimages centos 9-Stream -add ssh,python,postgresql")
	fmt.Println()
	fmt.Println("  # 完整LAMP环境")
	fmt.Println("  lxdimages ubuntu noble -add ssh,apache,mysql,php")
	fmt.Println()
	fmt.Println("  # 完整开发环境")
	fmt.Println("  lxdimages debian trixie -add ssh,git,nodejs,python,redis")
	fmt.Println()
	fmt.Println("  # 导出镜像")
	fmt.Println("  lxdimages alpine 3.22 -add ssh,docker -export")
}

