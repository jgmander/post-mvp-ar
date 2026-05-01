# Prompt Structure SOP
All future directives from the Brain will strictly follow a 4-part structure:
1. Context Verification
2. Execution Steps
3. Boundary/Security Check
4. Sync & Commit

# GCP Authentication
SOP for Service Account execution: "Ensure the service account is properly activated via its local JSON credential file using gcloud auth activate-service-account ag-agent@dbomar-post-mvp.iam.gserviceaccount.com --key-file=[PATH_TO_KEY] before attempting to fetch secrets, OR use --impersonate-service-account if configured by the Architect."
