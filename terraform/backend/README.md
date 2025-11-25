# Terraform Backend Bootstrap

이 모듈은 Terraform state 관리를 위한 S3 bucket과 DynamoDB table을 생성합니다.

## 사용법

### 1. Backend 리소스 생성 (최초 1회)

```bash
cd terraform/backend
terraform init
terraform apply
```

### 2. Output 확인

```bash
terraform output backend_config
```

출력 예시:
```hcl
{
  "bucket" = "nebula-terraform-state"
  "dynamodb_table" = "nebula-terraform-locks"
  "encrypt" = true
  "region" = "ap-northeast-2"
}
```

### 3. 다른 Terraform 프로젝트에서 사용

```hcl
terraform {
  backend "s3" {
    bucket         = "nebula-terraform-state"
    key            = "monitoring/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "nebula-terraform-locks"
    encrypt        = true
  }
}
```

## 주의사항

1. **이 모듈은 로컬 state를 사용합니다**
   - Backend 자체는 remote state를 사용할 수 없음 (순환 참조)
   - `terraform.tfstate` 파일을 안전하게 보관하세요

2. **삭제 방지**
   - 실수로 삭제하지 않도록 주의
   - 필요시 `prevent_destroy = true` lifecycle 추가 권장

3. **권한 관리**
   - S3 bucket과 DynamoDB table에 대한 IAM 권한 필요
   - 최소 권한 원칙 적용

## 필요 IAM 권한

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:GetBucket*",
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::nebula-terraform-state*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DescribeTable",
        "dynamodb:TagResource"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/nebula-terraform-locks"
    }
  ]
}
```
