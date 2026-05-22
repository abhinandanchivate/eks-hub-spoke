#!/usr/bin/env bash
# bootstrap-env.sh — auto-resolves all env vars, then runs deploy.sh
set -euo pipefail

DOMAIN="${1:-api.example.com}"   # pass your domain as arg: ./bootstrap-env.sh api.myapp.com

echo "==> Resolving AWS region"
export AWS_DEFAULT_REGION=$(
  curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/placement/region \
  || aws configure get region \
  || echo "ap-south-1"
)
echo "    Region: ${AWS_DEFAULT_REGION}"

echo "==> Resolving DB password from Secrets Manager"
aws secretsmanager create-secret \
  --name "bootstrap/db-password" \
  --secret-string "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9@#!' | head -c 20)" \
  --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true
export DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "bootstrap/db-password" \
  --query SecretString --output text)
echo "    DB_PASSWORD retrieved from Secrets Manager"

echo "==> Resolving ACM certificate for ${DOMAIN}"
export ACM_CERT_ARN=$(aws acm list-certificates \
  --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?contains(DomainName, '${DOMAIN}') || DomainName=='*.${DOMAIN}'].CertificateArn | [0]" \
  --output text)

if [ "${ACM_CERT_ARN}" == "None" ] || [ -z "${ACM_CERT_ARN}" ]; then
  echo "    No cert found — requesting new cert for ${DOMAIN}"
  export ACM_CERT_ARN=$(aws acm request-certificate \
    --domain-name "${DOMAIN}" \
    --subject-alternative-names "*.${DOMAIN}" \
    --validation-method DNS \
    --query CertificateArn --output text)
  echo "    Cert requested: ${ACM_CERT_ARN}"
  echo "    Add the DNS CNAME shown below to your DNS provider, then re-run."
  aws acm describe-certificate \
    --certificate-arn "${ACM_CERT_ARN}" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord"
  exit 1
fi
echo "    ACM_CERT_ARN: ${ACM_CERT_ARN}"

echo ""
echo "All env vars resolved:"
echo "  AWS_DEFAULT_REGION = ${AWS_DEFAULT_REGION}"
echo "  DB_PASSWORD        = *** (from Secrets Manager)"
echo "  ACM_CERT_ARN       = ${ACM_CERT_ARN}"
echo ""
echo "==> Running deploy.sh"
chmod +x deploy.sh && ./deploy.sh