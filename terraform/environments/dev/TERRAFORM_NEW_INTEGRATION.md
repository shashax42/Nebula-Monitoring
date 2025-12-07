# terraform_new 인프라 모니터링 연동 가이드 (dev)

이 문서는 **terraform_new-main 인프라**를 **Nebula-Monitoring 스택(AMP/AMG/X-Ray/CloudWatch)** 에 연결하는 최소 실행 순서를 정리합니다.

대상 환경:
- 인프라 레포: `terraform_new-main`
- 모니터링 레포: `Nebula-Monitoring` (현재 이 레포)
- 리전: `ap-northeast-2`

---

## 1. terraform_new 인프라 올리기

**레포:** `terraform_new-main`

```bash
cd terraform_new-main/environments/dev

# (필요 시) backend 설정 확인 후 init
terraform init \
  -backend-config="../../shared/backend-config/dev.hcl"

terraform apply
```

결과:
- EKS 클러스터, VPC, RDS, Redis 등 생성
- S3 버킷 `lucia-real-buckets` 의 `env/dev/terraform.tfstate` 에 state 저장
- `outputs.cluster_name` 에 EKS 클러스터 이름 기록

---

## 2. Nebula 모니터링 스택 + terraform_new 연결

**레포:** `Nebula-Monitoring`

```bash
cd Nebula-Monitoring/terraform/environments/dev

terraform init
terraform apply -var="enable_target_monitoring=true"
```

이 명령으로 하는 일:
- AMP, AMG, X-Ray, CloudWatch(로그/알람) 등 모니터링 스택 생성
- S3 state(`env/dev/terraform.tfstate`) 에서 **terraform_new의 `cluster_name` 자동 조회**
- 해당 클러스터용:
  - OTEL Collector IRSA Role + Policy(AMP, CloudWatch Logs, CloudWatch Metrics, X-Ray)
  - CloudWatch Log Group
    - `/aws/eks/<cluster_name>/otel-collector`
    - `/aws/eks/<cluster_name>/application`
- Helm 배포에 필요한 값/명령어 출력

유용한 output:

```bash
terraform output target_cluster_name
terraform output target_otel_role_arn
terraform output target_otel_log_group
terraform output -raw helm_install_command
```

---

## 3. OTEL Collector Helm 배포 (terraform_new 클러스터 내부)

1. **Helm 배포 명령어 확인**

   ```bash
   cd Nebula-Monitoring/terraform/environments/dev
   terraform output -raw helm_install_command
   ```

2. **출력된 명령어 그대로 실행**

   예시 형태:

   ```bash
   # 1) terraform_new EKS 클러스터 kubeconfig 설정
   aws eks update-kubeconfig --name eks-cluster-xxxx --region ap-northeast-2

   # 2) OTEL Collector Helm 배포
   helm upgrade --install otel-collector ../../helm/otel-collector \
     --namespace monitoring --create-namespace \
     -f ../../helm/otel-collector/values-target-infra.yaml \
     --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="...role-arn..." \
     --set config.exporters.prometheusremotewrite.endpoint="...remote_write_url..." \
     --set config.exporters.awscloudwatchlogs.log_group_name="/aws/eks/eks-cluster-xxxx/otel-collector" \
     --set config.processors.resource.attributes[0].value="eks-cluster-xxxx"
   ```

결과:
- terraform_new EKS 클러스터 안에 OTEL Collector 배포
- 메트릭 → AMP, 트레이스 → X-Ray, 로그 → CloudWatch Logs 로 전송 가능 상태

---

## 4. 모니터링 동작 확인

### 4.1 OTEL Collector 상태

```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
```

### 4.2 CloudWatch 로그 그룹

- `/aws/eks/<cluster_name>/otel-collector`
- `/aws/eks/<cluster_name>/application`

### 4.3 AMP / Grafana

```bash
cd Nebula-Monitoring/terraform/environments/dev
terraform output amp_remote_write_url
terraform output grafana_workspace_endpoint
```

- Grafana(AMG) 접속 후 AMP 데이터 소스에서 예시 쿼리:

  ```promql
  up{cluster="terraform-new"}
  ```

### 4.4 X-Ray

```bash	erraform output xray_service_map_url
terraform output xray_traces_url
```

AWS X-Ray 콘솔에서 서비스 맵/트레이스가 생성되는지 확인합니다.

---

## 5. 애플리케이션 계측 (향후 단계)

현재 문서는 **클라우드 인프라 + 모니터링 인프라 연결**까지만 다룹니다.
애플리케이션 지표/트레이스를 보내려면:

- Deployment에 Prometheus 스크랩 어노테이션 추가
- OTEL OTLP 엔드포인트/서비스 이름 환경변수 설정

예시:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
---
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-collector.monitoring.svc.cluster.local:4317"
            - name: OTEL_SERVICE_NAME
              value: "my-app"
```
