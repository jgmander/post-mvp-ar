#!/bin/bash
PAYLOAD_FILE="notebook_sync_payload.txt"
echo "=== Sync Payload Generated: $(date) ===" > $PAYLOAD_FILE
for file in .agent_rules.md .agent/notebook_workflow_SOP.md .agent/audit_architecture.md .agent/current_sprint.md; do
  if [ -f "$file" ]; then
    echo -e "\n\n--- BEGIN $file ---\n" >> $PAYLOAD_FILE
    cat "$file" >> $PAYLOAD_FILE
    echo -e "\n--- END $file ---" >> $PAYLOAD_FILE
  fi
done
echo "Payload written to $PAYLOAD_FILE"
