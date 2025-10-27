#!/bin/bash

# =============================================================================
# OpenEMR SSL Certificate Manager
# =============================================================================
#
# Purpose:
#   Manages SSL certificates for OpenEMR on EKS using AWS Certificate Manager
#   (ACM) and Route53. Provides commands to request, validate, and deploy SSL
#   certificates for secure HTTPS access to the OpenEMR application.
#
# Key Features:
#   - Request SSL certificates from AWS Certificate Manager
#   - Automatic Route53 DNS validation record creation
#   - Certificate validation status checking
#   - OpenEMR deployment with SSL certificate configuration
#   - Current SSL configuration status display
#
# Prerequisites:
#   - AWS credentials with ACM and Route53 permissions
#   - Domain must be managed by Route53 (for auto-validation)
#   - kubectl configured for the target cluster
#   - Terraform state available for infrastructure details
#
# Usage:
#   ./ssl-cert-manager.sh {request|list|validate|auto-validate|deploy|status|help}
#
# Options:
#   request          Request a new SSL certificate for a domain
#   list             List all certificates in ACM
#   validate         Check validation status of a certificate
#   auto-validate    Automatically validate certificate with Route53 DNS
#   deploy           Deploy OpenEMR with SSL certificate
#   status           Show current SSL configuration
#   help             Show this help message
#
# Environment Variables:
#   AWS_REGION       AWS region for ACM (default: us-west-2)
#   CLUSTER_NAME     EKS cluster name (default: openemr-eks)
#   NAMESPACE        Kubernetes namespace (default: openemr)
#
# Examples:
#   ./ssl-cert-manager.sh request
#   ./ssl-cert-manager.sh auto-validate arn:aws:acm:...
#   ./ssl-cert-manager.sh deploy arn:aws:acm:...
#   ./ssl-cert-manager.sh status
#
# =============================================================================

set -e

# Color codes for terminal output - provides visual distinction between different message types
RED='\033[0;31m'      # Error messages and critical issues
GREEN='\033[0;32m'    # Success messages and positive feedback
YELLOW='\033[1;33m'   # Warning messages and cautionary information
BLUE='\033[0;34m'     # Info messages and general information
NC='\033[0m'          # Reset color to default

# Configuration variables - can be overridden by environment variables
AWS_REGION=${AWS_REGION:-"us-west-2"}       # AWS region where certificates are managed
CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"} # EKS cluster name for deployment
NAMESPACE=${NAMESPACE:-"openemr"}           # Kubernetes namespace for OpenEMR

show_usage() {
    echo -e "${BLUE}🔐 OpenEMR SSL Certificate Manager${NC}"
    echo "Usage: $0 {request|list|validate|auto-validate|deploy|status|help}"
    echo ""
    echo "Commands:"
    echo "  request <domain> [auto-dns]  - Request a new SSL certificate from AWS Certificate Manager"
    echo "                                 auto-dns: true (default) for automatic Route53 records, false for manual"
    echo "  list                        - List all SSL certificates in your account"
    echo "  validate <arn>              - Check certificate validation status"
    echo "  auto-validate <arn>         - Automatically create Route53 DNS records for certificate validation"
    echo "  deploy <arn>                - Deploy OpenEMR with the specified SSL certificate"
    echo "  status                      - Show current SSL configuration in the cluster"
    echo "  help                        - Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 request openemr.example.com              # Auto-create DNS records"
    echo "  $0 request openemr.example.com false        # Manual DNS validation"
    echo "  $0 auto-validate arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    echo "  $0 deploy arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    echo ""
    echo "Note: For development/testing, you can deploy without a certificate to use self-signed SSL"
}

# Function to request a new SSL certificate from AWS Certificate Manager
# This function handles both automatic Route53 DNS validation and manual validation
request_certificate() {
    local domain=$1              # Domain name for the certificate
    local auto_dns=${2:-"true"}  # Whether to automatically create Route53 DNS records

    # Validate required domain parameter
    if [ -z "$domain" ]; then
        echo -e "${RED}Error: Domain name is required${NC}"
        echo "Usage: $0 request <domain> [auto-dns]"
        echo "  auto-dns: true (default) to automatically create Route53 records, false for manual"
        exit 1
    fi

    echo -e "${YELLOW}Requesting SSL certificate for domain: $domain${NC}"

    CERT_ARN=$(aws acm request-certificate \
        --domain-name "$domain" \
        --validation-method DNS \
        --region "$AWS_REGION" \
        --query 'CertificateArn' \
        --output text)

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to request certificate${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Certificate request submitted successfully!${NC}"
    echo -e "${YELLOW}Certificate ARN:${NC} $CERT_ARN"
    echo ""

    if [ "$auto_dns" = "true" ]; then
        echo -e "${YELLOW}⏳ Waiting for DNS validation records to be available...${NC}"
        sleep 10  # Wait for AWS to generate validation records

        # Get the hosted zone ID for the domain
        HOSTED_ZONE_ID=$(get_hosted_zone_id "$domain")
        if [ -z "$HOSTED_ZONE_ID" ]; then
            echo -e "${RED}❌ Could not find Route53 hosted zone for domain: $domain${NC}"
            echo -e "${YELLOW}Please ensure you have a Route53 hosted zone for this domain${NC}"
            echo -e "${YELLOW}Or run with manual DNS: $0 request $domain false${NC}"
            exit 1
        fi

        echo -e "${GREEN}✅ Found Route53 hosted zone: $HOSTED_ZONE_ID${NC}"

        # Create DNS validation records automatically
        if create_dns_validation_records "$CERT_ARN" "$HOSTED_ZONE_ID"; then
            echo -e "${GREEN}✅ DNS validation records created automatically!${NC}"
            echo ""
            echo -e "${YELLOW}Next steps:${NC}"
            echo "1. Wait for validation to complete (usually 5-30 minutes)"
            echo "2. Check validation status: $0 validate $CERT_ARN"
            echo "3. Deploy with certificate: $0 deploy $CERT_ARN"
        else
            echo -e "${RED}❌ Failed to create DNS validation records automatically${NC}"
            echo -e "${YELLOW}Falling back to manual DNS validation...${NC}"
            show_manual_dns_instructions "$CERT_ARN"
        fi
    else
        show_manual_dns_instructions "$CERT_ARN"
    fi
}

get_hosted_zone_id() {
    local domain=$1
    local base_domain

    # Try the exact domain first
    ZONE_ID=$(aws route53 list-hosted-zones \
        --query "HostedZones[?Name=='${domain}.'].Id" \
        --output text 2>/dev/null | sed 's|/hostedzone/||')

    if [ ! -z "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ]; then
        echo "$ZONE_ID"
        return 0
    fi

    # Try parent domains (e.g., for subdomain.example.com, try example.com)
    base_domain=$(echo "$domain" | sed 's/^[^.]*\.//')
    while [[ "$base_domain" == *.* ]]; do
        ZONE_ID=$(aws route53 list-hosted-zones \
            --query "HostedZones[?Name=='${base_domain}.'].Id" \
            --output text 2>/dev/null | sed 's|/hostedzone/||')

        if [ ! -z "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ]; then
            echo "$ZONE_ID"
            return 0
        fi

        base_domain=$(echo "$base_domain" | sed 's/^[^.]*\.//')
    done

    return 1
}

create_dns_validation_records() {
    local cert_arn=$1
    local hosted_zone_id=$2

    echo -e "${YELLOW}Creating DNS validation records in Route53...${NC}"

    # Get validation records from ACM
    local validation_data
    validation_data=$(aws acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$AWS_REGION" \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
        --output json 2>/dev/null)

    if [ -z "$validation_data" ] || [ "$validation_data" = "null" ]; then
        echo -e "${RED}❌ Could not retrieve validation records from ACM${NC}"
        echo -e "${YELLOW}The certificate might still be processing. Wait a few seconds and try again.${NC}"
        return 1
    fi

    # Extract individual values
    local record_name=$(echo "$validation_data" | jq -r '.Name')
    local record_type=$(echo "$validation_data" | jq -r '.Type')
    local record_value=$(echo "$validation_data" | jq -r '.Value')

    if [ -z "$record_name" ] || [ "$record_name" = "null" ] || [ -z "$record_value" ] || [ "$record_value" = "null" ]; then
        echo -e "${RED}❌ Invalid validation record data received${NC}"
        return 1
    fi

    echo -e "${BLUE}Creating DNS record:${NC}"
    echo -e "${BLUE}  Name: ${NC}$record_name"
    echo -e "${BLUE}  Type: ${NC}$record_type"
    echo -e "${BLUE}  Value: ${NC}$record_value"

    # Create change batch with JSON structure
    local change_batch=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "CREATE",
            "ResourceRecordSet": {
                "Name": "$record_name",
                "Type": "$record_type",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "$record_value"
                    }
                ]
            }
        }
    ]
}
EOF
)

    # Apply the change batch
    local change_result
    change_result=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$hosted_zone_id" \
        --change-batch "$change_batch" \
        --output json 2>&1)

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        local change_id=$(echo "$change_result" | jq -r '.ChangeInfo.Id' 2>/dev/null)
        echo -e "${GREEN}✅ DNS validation records created successfully${NC}"
        echo -e "${YELLOW}Change ID:${NC} $change_id"
        return 0
    else
        echo -e "${RED}❌ Failed to create DNS validation records${NC}"
        echo -e "${RED}Error details:${NC} $change_result"

        # Check for common errors
        if echo "$change_result" | grep -q "already exists"; then
            echo -e "${YELLOW}💡 The DNS record might already exist. This could be normal.${NC}"
            return 0
        elif echo "$change_result" | grep -q "InvalidChangeBatch"; then
            echo -e "${YELLOW}💡 Invalid change batch. The record format might be incorrect.${NC}"
        elif echo "$change_result" | grep -q "AccessDenied"; then
            echo -e "${YELLOW}💡 Access denied. Check your Route53 permissions.${NC}"
        fi

        return 1
    fi
}

show_manual_dns_instructions() {
    local cert_arn=$1

    echo -e "${YELLOW}Manual DNS validation required:${NC}"
    echo "1. Complete DNS validation in the AWS Console:"
    echo "   https://console.aws.amazon.com/acm/home?region=$AWS_REGION"
    echo "2. Add the required DNS records to your domain"
    echo "3. Wait for validation to complete (usually 5-30 minutes)"
    echo "4. Check validation status: $0 validate $cert_arn"
    echo "5. Deploy with certificate: $0 deploy $cert_arn"
}

list_certificates() {
    echo -e "${YELLOW}Listing SSL certificates in region $AWS_REGION:${NC}"
    echo ""

    aws acm list-certificates \
        --region "$AWS_REGION" \
        --query 'CertificateSummaryList[*].{Domain:DomainName,ARN:CertificateArn,Status:Status}' \
        --output table
}

validate_certificate() {
    local cert_arn=$1
    if [ -z "$cert_arn" ]; then
        echo -e "${RED}Error: Certificate ARN is required${NC}"
        echo "Usage: $0 validate <certificate-arn>"
        exit 1
    fi

    echo -e "${YELLOW}Checking validation status for certificate:${NC}"
    echo "$cert_arn"
    echo ""

    CERT_STATUS=$(aws acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$AWS_REGION" \
        --query 'Certificate.Status' \
        --output text)

    if [ "$CERT_STATUS" = "ISSUED" ]; then
        echo -e "${GREEN}✅ Certificate is validated and ready to use!${NC}"
        echo ""
        echo -e "${YELLOW}Deploy with this certificate:${NC}"
        echo "export SSL_CERT_ARN=\"$cert_arn\""
        echo "cd k8s && ./deploy.sh"
        echo ""
        echo -e "${YELLOW}Or use the deploy command:${NC}"
        echo "$0 deploy $cert_arn"
    elif [ "$CERT_STATUS" = "PENDING_VALIDATION" ]; then
        echo -e "${YELLOW}⏳ Certificate is pending validation${NC}"
        echo ""
        echo "DNS validation records needed:"
        aws acm describe-certificate \
            --certificate-arn "$cert_arn" \
            --region "$AWS_REGION" \
            --query 'Certificate.DomainValidationOptions[*].{Domain:DomainName,Name:ResourceRecord.Name,Value:ResourceRecord.Value,Type:ResourceRecord.Type}' \
            --output table
        echo ""
        echo -e "${YELLOW}Add these DNS records to your domain and wait for validation${NC}"
    else
        echo -e "${RED}❌ Certificate status: $CERT_STATUS${NC}"
        aws acm describe-certificate \
            --certificate-arn "$cert_arn" \
            --region "$AWS_REGION" \
            --query 'Certificate.{Status:Status,FailureReason:FailureReason}' \
            --output table
    fi
}

deploy_with_certificate() {
    local cert_arn=$1
    if [ -z "$cert_arn" ]; then
        echo -e "${RED}Error: Certificate ARN is required${NC}"
        echo "Usage: $0 deploy <certificate-arn>"
        exit 1
    fi

    # Validate certificate first
    echo -e "${YELLOW}Validating certificate before deployment...${NC}"
    CERT_STATUS=$(aws acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$AWS_REGION" \
        --query 'Certificate.Status' \
        --output text)

    if [ "$CERT_STATUS" != "ISSUED" ]; then
        echo -e "${RED}❌ Certificate is not in ISSUED status (current: $CERT_STATUS)${NC}"
        echo "Please ensure the certificate is validated before deploying"
        exit 1
    fi

    echo -e "${GREEN}✅ Certificate is valid, proceeding with deployment...${NC}"

    # Detect script location and set project root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ "$SCRIPT_DIR" == */scripts ]]; then
        PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
    else
        PROJECT_ROOT="$SCRIPT_DIR"
    fi

    if [ ! -f "$PROJECT_ROOT/k8s/deploy.sh" ]; then
        echo -e "${RED}❌ Could not find k8s/deploy.sh at $PROJECT_ROOT/k8s/deploy.sh${NC}"
        echo -e "${YELLOW}Please ensure you're running from the correct project directory.${NC}"
        exit 1
    fi

    # Set environment variable and deploy
    export SSL_CERT_ARN="$cert_arn"
    echo -e "${YELLOW}Deploying OpenEMR with SSL certificate...${NC}"
    echo -e "${YELLOW}Certificate ARN:${NC} $cert_arn"

    cd "$PROJECT_ROOT/k8s"
    ./deploy.sh

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Deployment completed successfully with SSL certificate!${NC}"
        echo ""
        echo -e "${YELLOW}Your OpenEMR instance is now accessible with trusted SSL:${NC}"
        LB_URL=$(kubectl get svc openemr-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ ! -z "$LB_URL" ]; then
            echo "HTTPS URL: https://$LB_URL"
        fi
    else
        echo -e "${RED}❌ Deployment failed${NC}"
        exit 1
    fi
}

show_status() {
    echo -e "${YELLOW}Current SSL configuration in cluster:${NC}"
    echo ""

    # Check if service exists
    if ! kubectl get service openemr-service -n $NAMESPACE >/dev/null 2>&1; then
        echo -e "${RED}❌ OpenEMR service not found. Deploy the application first.${NC}"
        exit 1
    fi

    # Check service annotations for SSL configuration
    SSL_CERT=$(kubectl get service openemr-service -n $NAMESPACE -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-ssl-cert}' 2>/dev/null)
    SSL_PORTS=$(kubectl get service openemr-service -n $NAMESPACE -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-ssl-ports}' 2>/dev/null)

    if [ ! -z "$SSL_CERT" ] && [ "$SSL_CERT" != "null" ]; then
        echo -e "${GREEN}✅ SSL Mode: AWS Certificate Manager${NC}"
        echo -e "${YELLOW}Certificate ARN:${NC} $SSL_CERT"

        # Validate certificate status
        CERT_STATUS=$(aws acm describe-certificate \
            --certificate-arn "$SSL_CERT" \
            --region "$AWS_REGION" \
            --query 'Certificate.Status' \
            --output text 2>/dev/null)

        if [ "$CERT_STATUS" = "ISSUED" ]; then
            echo -e "${GREEN}Certificate Status: ✅ Valid${NC}"
        else
            echo -e "${RED}Certificate Status: ❌ $CERT_STATUS${NC}"
        fi
    else
        echo -e "${YELLOW}SSL Mode: Self-Signed Certificates${NC}"
        echo -e "${YELLOW}Note: Browsers will show security warnings${NC}"
    fi

    # Show service ports
    echo ""
    echo -e "${YELLOW}Available ports:${NC}"
    kubectl get service openemr-service -n $NAMESPACE -o custom-columns=NAME:.metadata.name,PORTS:.spec.ports[*].port

    # Show LoadBalancer URL
    LB_URL=$(kubectl get svc openemr-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ ! -z "$LB_URL" ]; then
        echo ""
        echo -e "${YELLOW}Access URLs:${NC}"
        echo "HTTPS: https://$LB_URL"
    fi
}

auto_validate_certificate() {
    local cert_arn=$1
    if [ -z "$cert_arn" ]; then
        echo -e "${RED}Error: Certificate ARN is required${NC}"
        echo "Usage: $0 auto-validate <certificate-arn>"
        exit 1
    fi

    echo -e "${YELLOW}Auto-validating certificate:${NC}"
    echo "$cert_arn"
    echo ""

    # Check certificate status
    CERT_STATUS=$(aws acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$AWS_REGION" \
        --query 'Certificate.Status' \
        --output text)

    if [ "$CERT_STATUS" = "ISSUED" ]; then
        echo -e "${GREEN}✅ Certificate is already validated and ready to use!${NC}"
        return 0
    elif [ "$CERT_STATUS" != "PENDING_VALIDATION" ]; then
        echo -e "${RED}❌ Certificate status: $CERT_STATUS${NC}"
        echo "Auto-validation only works for certificates in PENDING_VALIDATION status"
        exit 1
    fi

    # Get the domain name from the certificate
    DOMAIN=$(aws acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$AWS_REGION" \
        --query 'Certificate.DomainName' \
        --output text)

    echo -e "${YELLOW}Certificate domain: $DOMAIN${NC}"

    # Get the hosted zone ID for the domain
    HOSTED_ZONE_ID=$(get_hosted_zone_id "$DOMAIN")
    if [ -z "$HOSTED_ZONE_ID" ]; then
        echo -e "${RED}❌ Could not find Route53 hosted zone for domain: $DOMAIN${NC}"
        echo -e "${YELLOW}Please ensure you have a Route53 hosted zone for this domain${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ Found Route53 hosted zone: $HOSTED_ZONE_ID${NC}"

    # Create DNS validation records
    if create_dns_validation_records "$cert_arn" "$HOSTED_ZONE_ID"; then
        echo -e "${GREEN}✅ DNS validation records created successfully!${NC}"
        echo ""
        echo -e "${YELLOW}Next steps:${NC}"
        echo "1. Wait for validation to complete (usually 5-30 minutes)"
        echo "2. Check validation status: $0 validate $cert_arn"
        echo "3. Deploy with certificate: $0 deploy $cert_arn"
    else
        echo -e "${RED}❌ Failed to create DNS validation records${NC}"
        exit 1
    fi
}

# Main script logic
case "$1" in
    "request")
        request_certificate "$2" "$3"
        ;;
    "list")
        list_certificates
        ;;
    "validate")
        validate_certificate "$2"
        ;;
    "auto-validate")
        auto_validate_certificate "$2"
        ;;
    "deploy")
        deploy_with_certificate "$2"
        ;;
    "status")
        show_status
        ;;
    "help"|"")
        show_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo ""
        show_usage
        exit 1
        ;;
esac
