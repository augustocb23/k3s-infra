echo "Installing AWS CLI..."
apt-get install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip

echo "Creating autoscaler script..."
cat <<'EOF' > /usr/local/bin/simple-scaler.sh
#!/bin/bash

# check for NotReady nodes and remove them if missing in AWS (janitor)
CLEANUP_DONE=0
NOT_READY_NODES=$(kubectl get nodes --no-headers | grep "NotReady" | awk '{print $1}')
for NODE in $NOT_READY_NODES; do
    log WARN "Node $NODE is NotReady. Checking if it still exists..."
    
    INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE.ec2.internal" "Name=instance-state-name,Values=running,pending" --query "Reservations[0].Instances[0].State.Name" --output text)
    if [ "$INSTANCE_STATE" == "None" ] || [ -z "$INSTANCE_STATE" ]; then
        log INFO "Node '$NODE' is NotReady in K8s and MISSING. Deleting node..."
        kubectl delete node $NODE > /dev/null 2>&1
    else
        log INFO "Node $NODE is NotReady but still exists (State: $INSTANCE_STATE). Waiting for recovery."
    fi
done

if [ "$CLEANUP_DONE" -eq 1 ]; then
    log INFO "Janitor finished. Waiting up for Scheduler to rebalance..."
    
    kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o name | \
    xargs -r kubectl wait --for=condition=PodScheduled --timeout=15s > /dev/null 2>&1
    
    log INFO "Rebalancing wait finished."
fi

# scale up if there are pending pods
PENDING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
if [ "$PENDING_PODS" -gt 0 ]; then
    log INFO "Detected $PENDING_PODS pending pods. Checking capacity..."
    CURRENT_CAPACITY=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query "AutoScalingGroups[0].DesiredCapacity" --output text)
    MAX_SIZE=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query "AutoScalingGroups[0].MaxSize" --output text)
    
    if [ "$CURRENT_CAPACITY" == "None" ] || [ -z "$CURRENT_CAPACITY" ]; then
        log ERROR "Could not read ASG '$ASG_NAME'. Check permissions or naming."
        exit 1
    fi

    if [ "$CURRENT_CAPACITY" -lt "$MAX_SIZE" ]; then
        NEW_CAPACITY=$((CURRENT_CAPACITY + 1))
        log INFO "Scaling up from $CURRENT_CAPACITY to $NEW_CAPACITY..."
        
        aws autoscaling set-desired-capacity --auto-scaling-group-name $ASG_NAME --desired-capacity $NEW_CAPACITY
        
        if [ $? -eq 0 ]; then
             log SUCCESS "Scaling command sent."
        else
             log ERROR "Failed to send scaling command."
        fi
        exit 0
    else
        log WARN "Max node limit ($MAX_SIZE) reached. Cannot scale up."
        exit 0
    fi
else
    log INFO "Cluster healthy. No pending pods."
fi

# scale down if nodes are underutilized
log INFO "Checking for underutilized nodes..."
CURRENT_CAPACITY=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query "AutoScalingGroups[0].DesiredCapacity" --output text)

if [ "$CURRENT_CAPACITY" -le 1 ]; then
    log INFO "Only one node present. Skipping scale down."
    exit 0
fi

NODES=$(kubectl get nodes --no-headers | grep -v "control-plane" | grep -v "master" | awk '{print $1}')
for NODE in $NODES; do
    NON_SYSTEM_PODS=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$NODE --no-headers | grep -v "kube-system" | grep -v "Completed" | grep -v "Terminating" | wc -l)

    if [ "$NON_SYSTEM_PODS" -eq 0 ]; then
        log INFO "Node '$NODE' appears empty (0 application pods). Preparing to terminate..."
        kubectl cordon $NODE
        
        INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE.ec2.internal" --query "Reservations[0].Instances[0].InstanceId" --output text)
        if [ -z "$INSTANCE_ID" ]; then
            log ERROR "Could not resolve Instance ID for node $NODE. Skipping."
            kubectl uncordon $NODE
            continue
        fi

        log INFO "Terminating instance '$INSTANCE_ID' (node '$NODE') and decrementing capacity..."
        aws autoscaling terminate-instance-in-auto-scaling-group --instance-id $INSTANCE_ID --should-decrement-desired-capacity > /dev/null
        
        if [ $? -eq 0 ]; then
            log SUCCESS "Scale down command sent for '$INSTANCE_ID'. Removing node '$NODE' from cluster."
            kubectl delete node $NODE > /dev/null 2>&1
            exit 0 # Only kill one node per execution cycle for safety
        else
            log ERROR "Failed to terminate instance. Uncordoning node."
            kubectl uncordon $NODE
        fi
    fi
done
EOF

chmod +x /usr/local/bin/simple-scaler.sh
echo "* * * * * root /usr/local/bin/simple-scaler.sh" >> /etc/crontab
