#!/bin/bash

set -e

CLUSTER_NAME=${CLUSTER_NAME:-"openemr-eks"}
REGION=${AWS_REGION:-"us-west-2"}

show_usage() {
    echo "🔐 OpenEMR Cluster Security Manager"
    echo "Usage: $0 {enable|disable|status|auto-disable|check-ip}"
    echo ""
    echo "Commands:"
    echo "  enable       - Enable public access with your current IP"
    echo "  disable      - Disable public access (private only)"
    echo "  status       - Show current access configuration"
    echo "  auto-disable [MINUTES] - Set up automatic disable (default: 120 minutes)"
    echo "  check-ip     - Check if your IP has changed"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_UPDATE_TIMEOUT - Timeout in minutes for cluster updates (default: 5)"
    echo ""
    echo "Security Best Practice: Always disable public access when not managing the cluster"
}

get_current_ip() {
    curl -s https://checkip.amazonaws.com 2>/dev/null || curl -s https://whatismyip.akamai.com/ 2>/dev/null || echo "Unable to detect IP"
}

get_allowed_ips() {
    # Get the first CIDR from the array, handle empty arrays gracefully
    # Use a more robust approach to handle the output
    local cidr=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
      --query 'cluster.resourcesVpcConfig.publicAccessCidrs[0]' --output text 2>/dev/null)

    if [ -n "$cidr" ] && [ "$cidr" != "None" ] && [ "$cidr" != "null" ]; then
        echo "$cidr"
    else
        echo "None"
    fi
}

case "$1" in
  "enable")
    echo "🔓 Enabling public access for cluster management..."
    CURRENT_IP=$(get_current_ip)

    if [ "$CURRENT_IP" = "Unable to detect IP" ]; then
        echo "❌ Unable to detect your current IP address"
        echo "💡 Please check your internet connection and try again"
        exit 1
    fi

    echo "Your current IP: $CURRENT_IP"

    aws eks update-cluster-config \
      --region $REGION \
      --name $CLUSTER_NAME \
      --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs="$CURRENT_IP/32"

    if [ $? -eq 0 ]; then
        echo "✅ Public access enabled for IP: $CURRENT_IP"
        echo "⚠️  Remember to disable public access when finished!"
        echo "💡 Run: $0 disable"
        echo "🕐 Or set auto-disable: $0 auto-disable"

        # Poll for cluster update completion with progress
        echo "⏳ Waiting for cluster update to complete..."
        echo "📊 This typically takes 2-3 minutes..."

        # Set timeout and polling interval
        TIMEOUT_MINUTES=${CLUSTER_UPDATE_TIMEOUT:-5}
        POLLING_INTERVAL=10  # Check every 10 seconds for faster updates
        TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
        START_TIME=$(date +%s)

        echo "🔄 Starting status monitoring..."

        while true; do
            CURRENT_TIME=$(date +%s)
            ELAPSED_SECONDS=$((CURRENT_TIME - START_TIME))
            REMAINING_SECONDS=$((TIMEOUT_SECONDS - ELAPSED_SECONDS))

            if [ $REMAINING_SECONDS -le 0 ]; then
                echo "⏰ Timeout reached (${TIMEOUT_MINUTES} minutes)"
                echo "💡 Cluster may still be updating. Check status with: $0 status"
                break
            fi

            # Check cluster status
            CLUSTER_STATUS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
              --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")

            if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
                ELAPSED_MINUTES=$((ELAPSED_SECONDS / 60))
                echo "✅ Cluster update completed successfully! (Total time: ${ELAPSED_MINUTES}m)"
                break
            elif [ "$CLUSTER_STATUS" = "UPDATING" ]; then
                ELAPSED_MINUTES=$((ELAPSED_SECONDS / 60))
                REMAINING_MINUTES=$((REMAINING_SECONDS / 60))
                echo "⏳ Status: $CLUSTER_STATUS | Elapsed: ${ELAPSED_MINUTES}m | Remaining: ${REMAINING_MINUTES}m"
            else
                echo "⚠️  Unexpected cluster status: $CLUSTER_STATUS"
                echo "💡 Waiting for status to stabilize..."
            fi

            sleep $POLLING_INTERVAL
        done

        # Update kubeconfig
        echo "🔄 Updating kubeconfig..."
        aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

        # Wait for networking to stabilize with loading bar
        echo "⏳ Waiting for networking to stabilize (5 minutes)..."

        # Function to show loading bar
        show_loading_bar() {
            local elapsed=$1
            local total=$2
            local width=50
            local filled=$((elapsed * width / total))
            local empty=$((width - filled))

            printf "\r⏳ ["
            printf "%${filled}s" | tr ' ' '█'
            printf "%${empty}s" | tr ' ' '░'
            printf "] %d%% (%ds/%ds)" $((elapsed * 100 / total)) $elapsed $total
        }

        # Show loading bar during networking stabilization
        STABILIZATION_TIME=300  # 5 minutes
        STABILIZATION_START=$(date +%s)

        while true; do
            CURRENT_TIME=$(date +%s)
            ELAPSED=$((CURRENT_TIME - STABILIZATION_START))
            REMAINING=$((STABILIZATION_TIME - ELAPSED))

            if [ $REMAINING -le 0 ]; then
                echo ""  # New line after loading bar
                echo "🔄 Networking stabilization waiting completed"
                break
            fi

            show_loading_bar $ELAPSED $STABILIZATION_TIME
            sleep 1
        done

        # Test connection with improved logic
        echo "🧪 Testing cluster connection..."
        CONNECTION_ATTEMPTS=3
        CONNECTION_SUCCESS=false

        for attempt in $(seq 1 $CONNECTION_ATTEMPTS); do
            echo "  Attempt $attempt/$CONNECTION_ATTEMPTS..."

            # Try with better error handling
            # Use simple kubectl command since context is already set
            if kubectl get nodes >/dev/null 2>&1; then
                echo "✅ Cluster connection successful (EKS Auto Mode)"
                CONNECTION_SUCCESS=true
                break
            else
                if [ $attempt -lt $CONNECTION_ATTEMPTS ]; then
                    echo "  ⏳ Connection attempt failed, waiting 30 seconds before retry..."
                    echo "  💡 This is normal - cluster networking may still be stabilizing"
                    sleep 30
                fi
            fi
        done

        if [ "$CONNECTION_SUCCESS" = false ]; then
            echo "⚠️  Cluster connection test failed after $CONNECTION_ATTEMPTS attempts"
            echo "💡 This is normal for newly updated clusters. The cluster may need more time to stabilize."
            echo "💡 You can check status anytime with: $0 status"
            echo "💡 Or test manually with: kubectl get nodes"
            echo "💡 The cluster is likely working but networking is still stabilizing"
            echo "💡 You can also try: kubectl get nodes"
        fi
    else
        echo "❌ Failed to enable public access"
        exit 1
    fi
    ;;

  "disable")
    echo "🔒 Disabling public access for enhanced security..."
    aws eks update-cluster-config \
      --region $REGION \
      --name $CLUSTER_NAME \
      --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true

    if [ $? -eq 0 ]; then
        echo "✅ Public access disabled - cluster is now private-only"
        echo "🛡️  Cluster is now secure from external access"

        # Poll for cluster update completion with progress
        echo "⏳ Waiting for cluster update to complete..."
        echo "📊 This typically takes 2-3 minutes..."

        # Set timeout and polling interval
        TIMEOUT_MINUTES=${CLUSTER_UPDATE_TIMEOUT:-5}
        POLLING_INTERVAL=10  # Check every 10 seconds for faster updates
        TIMEOUT_SECONDS=$((TIMEOUT_MINUTES * 60))
        START_TIME=$(date +%s)

        echo "🔄 Starting status monitoring..."

        while true; do
            CURRENT_TIME=$(date +%s)
            ELAPSED_SECONDS=$((CURRENT_TIME - START_TIME))
            REMAINING_SECONDS=$((TIMEOUT_SECONDS - ELAPSED_SECONDS))

            if [ $REMAINING_SECONDS -le 0 ]; then
                echo "⏰ Timeout reached (${TIMEOUT_MINUTES} minutes)"
                echo "💡 Cluster may still be updating. Check status with: $0 status"
                break
            fi

            # Check cluster status
            CLUSTER_STATUS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
              --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")

            if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
                ELAPSED_MINUTES=$((ELAPSED_SECONDS / 60))
                echo "✅ Cluster update completed successfully! (Total time: ${ELAPSED_MINUTES}m)"
                break
            elif [ "$CLUSTER_STATUS" = "UPDATING" ]; then
                ELAPSED_MINUTES=$((ELAPSED_SECONDS / 60))
                REMAINING_MINUTES=$((REMAINING_SECONDS / 60))
                echo "⏳ Status: $CLUSTER_STATUS | Elapsed: ${ELAPSED_MINUTES}m | Remaining: ${REMAINING_MINUTES}m"
            else
                echo "⚠️  Unexpected cluster status: $CLUSTER_STATUS"
                echo "💡 Waiting for status to stabilize..."
            fi

            sleep $POLLING_INTERVAL
        done

                # Wait for networking to stabilize with loading bar
        echo "⏳ Waiting for networking to stabilize (5 minutes)..."

        # Function to show loading bar
        show_loading_bar() {
            local elapsed=$1
            local total=$2
            local width=50
            local filled=$((elapsed * width / total))
            local empty=$((width - filled))

            printf "\r⏳ ["
            printf "%${filled}s" | tr ' ' '█'
            printf "%${empty}s" | tr ' ' '░'
            printf "] %d%% (%ds/%ds)" $((elapsed * 100 / total)) $elapsed $total
        }

        # Show loading bar during networking stabilization
        STABILIZATION_TIME=300  # 5 minutes
        STABILIZATION_START=$(date +%s)

        while true; do
            CURRENT_TIME=$(date +%s)
            ELAPSED=$((CURRENT_TIME - STABILIZATION_START))
            REMAINING=$((STABILIZATION_TIME - ELAPSED))

            if [ $REMAINING -le 0 ]; then
                echo ""  # New line after loading bar
                echo "🔄 Networking stabilization waiting completed"
                break
            fi

            show_loading_bar $ELAPSED $STABILIZATION_TIME
            sleep 1
        done

        # Skip connection test when disabling access (it should fail by design)
        echo "🛡️  Skipping cluster connection test (public access disabled)"
        echo "✅ This is expected behavior - cluster is now secure and private-only"
        echo "💡 To re-enable access when needed, run: $0 enable"
    else
        echo "❌ Failed to disable public access"
        exit 1
    fi
    ;;

  "status")
    echo "📊 Current cluster endpoint configuration:"
    aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
      --query 'cluster.resourcesVpcConfig.{PublicAccess:endpointPublicAccess,PrivateAccess:endpointPrivateAccess,AllowedCIDRs:publicAccessCidrs}' \
      --output table

    # Check if public access is enabled
    PUBLIC_ACCESS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION \
      --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)

    if [ "$PUBLIC_ACCESS" = "True" ]; then
        echo "⚠️  WARNING: Public access is currently ENABLED"
        echo "🔒 For security, consider disabling: $0 disable"

        # Show IP comparison
        CURRENT_IP=$(get_current_ip)
        ALLOWED_IP=$(get_allowed_ips | cut -d'/' -f1)

        echo ""
        echo "IP Address Status:"
        echo "  Your current IP: $CURRENT_IP"
        echo "  Allowed IP: $ALLOWED_IP"

        if [ "$CURRENT_IP" != "$ALLOWED_IP" ]; then
            echo "❌ IP addresses don't match - you may not be able to access the cluster"
            echo "💡 Run: $0 enable (to update with your current IP)"
        else
            echo "✅ IP addresses match - you have cluster access"
        fi
    else
        echo "✅ SECURE: Public access is disabled"
    fi
    ;;

  "check-ip")
    CURRENT_IP=$(get_current_ip)

    # Check if cluster is accessible first
    if ! aws eks describe-cluster --name $CLUSTER_NAME --region $REGION >/dev/null 2>&1; then
        echo "❌ Cannot access cluster '$CLUSTER_NAME'"
        echo "💡 Cluster may be updating or not accessible"
        exit 1
    fi

    # Check cluster status
    CLUSTER_STATUS=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.status' --output text 2>/dev/null)
    if [ "$CLUSTER_STATUS" = "UPDATING" ]; then
        echo "⚠️  Cluster is currently updating - please wait for update to complete"
        echo "💡 Check status with: $0 status"
        exit 1
    fi

    ALLOWED_IP=$(get_allowed_ips | cut -d'/' -f1)

    echo "IP Address Check:"
    echo "  Your current IP: $CURRENT_IP"
    echo "  Allowed IP: $ALLOWED_IP"

    if [ "$CURRENT_IP" = "$ALLOWED_IP" ]; then
        echo "✅ IP addresses match - you have cluster access"

        # Test kubectl access with retry logic (macOS compatible)
        echo "🧪 Testing kubectl access..."

        # Try kubectl access with retries
        KUBECTL_SUCCESS=false
        for attempt in 1 2 3; do
            if kubectl get nodes >/dev/null 2>&1; then
                KUBECTL_SUCCESS=true
                break
            else
                if [ $attempt -lt 3 ]; then
                    echo "   Attempt $attempt/3 failed, retrying in 5 seconds..."
                    sleep 5
                fi
            fi
        done

        if [ "$KUBECTL_SUCCESS" = true ]; then
            echo "✅ kubectl access confirmed - cluster is fully accessible"
        else
            echo "⚠️  kubectl access failed after 3 attempts"
            echo "💡 This may be due to:"
            echo "   - Cluster endpoint still updating"
            echo "   - Temporary networking issue"
            echo "   - Kubeconfig needs refresh"
            echo "💡 Try running: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION"
            echo "💡 Or check cluster status with: $0 status"
        fi
    else
        echo "❌ IP addresses don't match"
        echo "💡 Your IP has changed. Run: $0 enable"
    fi
    ;;

  "auto-disable")
    # Get time parameter (default to 120 minutes = 2 hours)
    MINUTES=${2:-120}

    # Validate input
    if ! [[ "$MINUTES" =~ ^[0-9]+$ ]] || [ "$MINUTES" -lt 1 ]; then
        echo "❌ Invalid time parameter: '$MINUTES'"
        echo "💡 Usage: $0 auto-disable [MINUTES]"
        echo "💡 Example: $0 auto-disable 60 (for 1 hour)"
        echo "💡 Default: 120 minutes (2 hours) if no parameter provided"
        exit 1
    fi

    # Convert to seconds
    SECONDS=$((MINUTES * 60))

    # Format time for display
    if [ $MINUTES -eq 1 ]; then
        TIME_DISPLAY="1 minute"
    elif [ $MINUTES -lt 60 ]; then
        TIME_DISPLAY="${MINUTES} minutes"
    else
        HOURS=$((MINUTES / 60))
        REMAINING_MINUTES=$((MINUTES % 60))
        if [ $REMAINING_MINUTES -eq 0 ]; then
            TIME_DISPLAY="${HOURS} hour$(if [ $HOURS -ne 1 ]; then echo "s"; fi)"
        else
            TIME_DISPLAY="${HOURS} hour$(if [ $HOURS -ne 1 ]; then echo "s"; fi) and ${REMAINING_MINUTES} minute$(if [ $REMAINING_MINUTES -ne 1 ]; then echo "s"; fi)"
        fi
    fi

    echo "🕐 Setting up automatic disable in $TIME_DISPLAY..."

    # Check if 'at' command is available
    if ! command -v at >/dev/null 2>&1; then
        echo "⚠️  'at' command not available. Using alternative method..."

        # Create a background script
        cat > /tmp/auto-disable-cluster.sh << EOF
#!/bin/bash
sleep $SECONDS
$0 disable
echo "🔒 Auto-disabled cluster access at \$(date)" >> /tmp/cluster-auto-disable.log
EOF
        chmod +x /tmp/auto-disable-cluster.sh

        # Run in background
        nohup /tmp/auto-disable-cluster.sh >/dev/null 2>&1 &
        echo "✅ Auto-disable scheduled for $TIME_DISPLAY from now (background process)"
        echo "📝 Check log: tail -f /tmp/cluster-auto-disable.log"
    else
        # Use 'at' command
        if [ $MINUTES -lt 60 ]; then
            # For minutes, use "now + X minutes"
            echo "$0 disable" | at now + $MINUTES minutes 2>/dev/null
        else
            # For hours, use "now + X hours"
            HOURS=$((MINUTES / 60))
            echo "$0 disable" | at now + $HOURS hours 2>/dev/null
        fi

        if [ $? -eq 0 ]; then
            echo "✅ Auto-disable scheduled for $TIME_DISPLAY from now"
            echo "📅 Check scheduled jobs: atq"
            echo "❌ Cancel if needed: atrm JOB_NUMBER"
        else
            echo "❌ Failed to schedule auto-disable"
        fi
    fi
    ;;

  *)
    show_usage
    exit 1
    ;;
esac
