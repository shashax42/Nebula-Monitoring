# ========================================
# terraform_new 인프라 모니터링 배포 스크립트
# ========================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Environment = "dev",
    
    [Parameter(Mandatory=$false)]
    [string]$AwsProfile = "monitoring-admin",
    
    [Parameter(Mandatory=$false)]
    [string]$Region = "ap-northeast-2"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Nebula Monitoring - Target Infrastructure Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 경로 설정
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$TerraformDir = Join-Path $RootDir "terraform\environments\$Environment"
$HelmDir = Join-Path $RootDir "helm\otel-collector"

# ========================================
# Step 1: Terraform Apply (모니터링 인프라)
# ========================================
Write-Host "[Step 1/6] Terraform Apply - Monitoring Infrastructure" -ForegroundColor Yellow
Write-Host "Directory: $TerraformDir" -ForegroundColor Gray

Push-Location $TerraformDir
try {
    Write-Host "Initializing Terraform..." -ForegroundColor Gray
    terraform init
    
    Write-Host "Planning Terraform changes..." -ForegroundColor Gray
    terraform plan -out=tfplan
    
    Write-Host "Applying Terraform changes..." -ForegroundColor Gray
    terraform apply tfplan
    
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform apply failed"
    }
    
    Write-Host "✓ Terraform apply completed" -ForegroundColor Green
} finally {
    Pop-Location
}

# ========================================
# Step 2: Terraform Outputs 가져오기
# ========================================
Write-Host ""
Write-Host "[Step 2/6] Fetching Terraform Outputs" -ForegroundColor Yellow

Push-Location $TerraformDir
try {
    $TargetClusterName = terraform output -raw target_cluster_name
    $TargetOtelRoleArn = terraform output -raw target_otel_role_arn
    $AmpRemoteWriteUrl = terraform output -raw amp_remote_write_url
    $TargetLogGroup = "/aws/eks/$TargetClusterName/otel-collector"
    
    Write-Host "  Target Cluster: $TargetClusterName" -ForegroundColor Gray
    Write-Host "  OTEL Role ARN: $TargetOtelRoleArn" -ForegroundColor Gray
    Write-Host "  AMP Endpoint: $AmpRemoteWriteUrl" -ForegroundColor Gray
    Write-Host "✓ Outputs fetched" -ForegroundColor Green
} finally {
    Pop-Location
}

# ========================================
# Step 3: EKS 클러스터 kubeconfig 설정
# ========================================
Write-Host ""
Write-Host "[Step 3/6] Configuring kubectl for target cluster" -ForegroundColor Yellow

if ([string]::IsNullOrEmpty($TargetClusterName)) {
    Write-Host "⚠ No target cluster found. Skipping Helm deployment." -ForegroundColor Yellow
    exit 0
}

Write-Host "Updating kubeconfig for cluster: $TargetClusterName" -ForegroundColor Gray
aws eks update-kubeconfig --name $TargetClusterName --region $Region --profile $AwsProfile

if ($LASTEXITCODE -ne 0) {
    throw "Failed to update kubeconfig"
}

Write-Host "✓ kubeconfig updated" -ForegroundColor Green

# ========================================
# Step 4: Helm Install OTEL Collector
# ========================================
Write-Host ""
Write-Host "[Step 4/6] Deploying Kube-State-Metrics via Helm" -ForegroundColor Yellow

# Helm repo 추가
Write-Host "Adding Helm repositories..." -ForegroundColor Gray
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Kube-State-Metrics 설치 (Q1~Q4 쿼리에 필수)
$KsmValuesFile = Join-Path $RootDir "helm\kube-state-metrics\values.yaml"
Write-Host "Installing Kube-State-Metrics..." -ForegroundColor Gray
helm upgrade --install kube-state-metrics `
    prometheus-community/kube-state-metrics `
    --namespace monitoring `
    --values $KsmValuesFile `
    --wait `
    --timeout 3m

if ($LASTEXITCODE -ne 0) {
    Write-Host "⚠ Kube-State-Metrics install failed, continuing..." -ForegroundColor Yellow
} else {
    Write-Host "✓ Kube-State-Metrics deployed" -ForegroundColor Green
}

# ========================================
# Step 5: RBAC 설정
# ========================================
Write-Host ""
Write-Host "[Step 5/6] Applying RBAC for OTEL Collector" -ForegroundColor Yellow

$RbacFile = Join-Path $RootDir "helm\otel-collector\rbac.yaml"
if (Test-Path $RbacFile) {
    kubectl apply -f $RbacFile
    Write-Host "✓ RBAC applied" -ForegroundColor Green
} else {
    Write-Host "⚠ RBAC file not found: $RbacFile" -ForegroundColor Yellow
}

# ========================================
# Step 6: Helm Install OTEL Collector
# ========================================
Write-Host ""
Write-Host "[Step 6/6] Deploying OTEL Collector via Helm" -ForegroundColor Yellow

# monitoring namespace 생성
Write-Host "Creating monitoring namespace..." -ForegroundColor Gray
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Helm values 파일 경로
$ValuesFile = Join-Path $HelmDir "values-target-infra.yaml"
$TempValuesFile = Join-Path $env:TEMP "otel-values-override.yaml"

# Terraform outputs를 Helm values에 주입
Write-Host "Generating Helm values with Terraform outputs..." -ForegroundColor Gray

$ValuesContent = Get-Content $ValuesFile -Raw

# ServiceAccount annotations 주입
$ValuesContent = $ValuesContent -replace '# Terraform에서 주입: eks.amazonaws.com/role-arn:.*', "eks.amazonaws.com/role-arn: `"$TargetOtelRoleArn`""

# AMP endpoint 주입
$ValuesContent = $ValuesContent -replace '# Terraform에서 주입: endpoint:.*prometheusremotewrite', "endpoint: `"$AmpRemoteWriteUrl`""

# CloudWatch Logs 설정 주입
$ValuesContent = $ValuesContent -replace '# Terraform에서 주입: log_group_name, region', "log_group_name: `"$TargetLogGroup`"`n      region: `"$Region`""

# X-Ray region 주입
$ValuesContent = $ValuesContent -replace '# Terraform에서 주입: region', "region: `"$Region`""

# SigV4 region 주입
$ValuesContent = $ValuesContent -replace 'sigv4auth:\s*\n\s*# Terraform에서 주입: region', "sigv4auth:`n      region: `"$Region`""

$ValuesContent | Out-File -FilePath $TempValuesFile -Encoding UTF8

# Helm install/upgrade
Write-Host "Installing OTEL Collector..." -ForegroundColor Gray
helm upgrade --install otel-collector `
    open-telemetry/opentelemetry-collector `
    --namespace monitoring `
    --values $TempValuesFile `
    --wait `
    --timeout 5m

if ($LASTEXITCODE -ne 0) {
    throw "Helm install failed"
}

Write-Host "✓ OTEL Collector deployed" -ForegroundColor Green

# Cleanup
Remove-Item $TempValuesFile -ErrorAction SilentlyContinue

# ========================================
# 완료
# ========================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✓ Deployment Completed Successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Check OTEL Collector pods:" -ForegroundColor Gray
Write-Host "     kubectl get pods -n monitoring" -ForegroundColor White
Write-Host ""
Write-Host "  2. View OTEL Collector logs:" -ForegroundColor Gray
Write-Host "     kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector -f" -ForegroundColor White
Write-Host ""
Write-Host "  3. Access Grafana dashboard:" -ForegroundColor Gray
Write-Host "     Check Terraform output 'grafana_workspace_endpoint'" -ForegroundColor White
Write-Host ""
