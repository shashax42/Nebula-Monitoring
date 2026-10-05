# ========================================
# terraform_new 인프라 모니터링 배포 스크립트 (Windows)
#   Terraform → kube-state-metrics → OTel Collector(agent/gateway/cluster)
#   Grafana 대시보드는 Git Bash/WSL 에서 scripts/provision-grafana.sh 실행
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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$TerraformDir = Join-Path $RootDir "terraform\environments\$Environment"
$HelmDir = Join-Path $RootDir "helm\otel-collector"

function Step($msg) { Write-Host "▶ $msg" -ForegroundColor Yellow }

# ----------------------------------------
Step "[1/4] Terraform apply"
Push-Location $TerraformDir
try {
    terraform init
    terraform apply -var="enable_target_monitoring=true"
    if ($LASTEXITCODE -ne 0) { throw "Terraform apply failed" }

    $TargetClusterName = terraform output -raw target_cluster_name
    $TargetOtelRoleArn = terraform output -raw target_otel_role_arn
    $AmpRemoteWriteUrl = terraform output -raw amp_remote_write_url
} finally {
    Pop-Location
}

if ([string]::IsNullOrEmpty($TargetClusterName) -or [string]::IsNullOrEmpty($TargetOtelRoleArn)) {
    throw "target_cluster_name / target_otel_role_arn is empty. Check terraform_new remote state."
}
Write-Host "  Cluster : $TargetClusterName" -ForegroundColor Gray
Write-Host "  Role    : $TargetOtelRoleArn" -ForegroundColor Gray
Write-Host "  AMP     : $AmpRemoteWriteUrl" -ForegroundColor Gray

# ----------------------------------------
Step "[2/4] kubeconfig"
aws eks update-kubeconfig --name $TargetClusterName --region $Region --profile $AwsProfile
if ($LASTEXITCODE -ne 0) { throw "Failed to update kubeconfig" }
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# ----------------------------------------
Step "[3/4] kube-state-metrics"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
helm repo update prometheus-community
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics `
    --namespace monitoring `
    --values (Join-Path $RootDir "helm\kube-state-metrics\values.yaml") `
    --wait --timeout 3m
if ($LASTEXITCODE -ne 0) { throw "kube-state-metrics install failed" }

# ----------------------------------------
Step "[4/4] OTel Collector (agent / gateway / cluster)"
helm upgrade --install otel-collector $HelmDir `
    --namespace monitoring `
    --values (Join-Path $HelmDir "values-$Environment.yaml") `
    --values (Join-Path $HelmDir "values-target-infra.yaml") `
    --set "global.clusterName=$TargetClusterName" `
    --set "global.environment=$Environment" `
    --set "global.aws.region=$Region" `
    --set "global.aws.ampRemoteWriteUrl=$AmpRemoteWriteUrl" `
    --set "gateway.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$TargetOtelRoleArn" `
    --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "OTel Collector install failed" }

kubectl get pods -n monitoring -l app.kubernetes.io/name=otel-collector

Write-Host ""
Write-Host "✓ Deployment completed" -ForegroundColor Green
Write-Host "  App OTLP endpoint : http://otel-collector.monitoring.svc:4317" -ForegroundColor White
Write-Host "  Dashboards        : bash scripts/provision-grafana.sh $Environment" -ForegroundColor White
