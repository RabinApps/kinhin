#!/bin/bash
# Provision the throwaway Buildkite, Bitbucket and Azure DevOps resources the gated e2e lanes need, then store the
# lane secrets in GitHub Actions.
#
#   scripts/e2e-forges-setup.sh all
#   scripts/e2e-forges-setup.sh buildkite --buildkite-org my-e2e-org
#   scripts/e2e-forges-setup.sh azure --dry-run            # print every request, send none, ask for nothing
#   scripts/e2e-forges-setup.sh bitbucket --rotate         # a token is expiring: replace only that secret
#
# What it does (idempotent: every resource is looked up first and only created when missing):
#   buildkite  cluster, and the self-hosted queue with the key `kinhin`
#   bitbucket  private repository, a README commit on its main branch, Pipelines enabled
#   azure      private project, a README commit on its repository, a self-hosted agent pool, and the pool's
#              queue in the project authorized for all pipelines
# It then checks the narrow e2e token against the service with the same read-only calls as
# docs/e2e-hosted-forges.md, and sets the KINHIN_E2E_* secrets with `gh secret set`. It also asks when each token
# expires and stores the date as the repository variable KINHIN_E2E_<FORGE>_TOKEN_EXPIRES, which
# .github/workflows/e2e-token-expiry.yml turns into a reminder issue. Tokens cannot be created through an API, so
# --rotate is the whole rotation: it skips provisioning, checks the new token, and replaces its secret and expiry.
#
# What it deliberately does not do:
#   - create the organization, workspace or Azure DevOps organization, or mint the e2e tokens. Those are web-UI
#     steps; the script prints where, and prompts for the token afterwards.
#   - keep a credential. Tokens are typed at hidden prompts, held in shell variables, sent to curl through stdin
#     (never as arguments) and to `gh secret set` through stdin. The broader bootstrap credentials Bitbucket and
#     Azure need to create a repository or project are used for provisioning only.
#   - touch this Mac's fleet. It talks to the three services and to GitHub only. Dispatch the lanes with
#     `gh workflow run e2e.yml`; never run scripts/e2e.sh locally.
# See docs/e2e-hosted-forges.md for what each lane needs and why.
# shellcheck disable=SC2016  # the $vars in the jq filters are jq's, not the shell's
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage: scripts/e2e-forges-setup.sh <buildkite|bitbucket|azure|all> [options]

  --dry-run                  print each request and secret instead of sending it; prompts for nothing
  --no-secrets               provision and verify, but do not run `gh secret set` (or record the expiry)
  --rotate                   a token is expiring: provision nothing, check the new token, replace its secret
  --repo OWNER/NAME          GitHub repository that gets the secrets (default RabinApps/kinhin)
  --buildkite-org SLUG       --buildkite-cluster NAME      (default cluster kinhin-e2e)
  --bitbucket-workspace SLUG --bitbucket-repo SLUG         (default repository kinhin-e2e)
  --azure-org NAME_OR_URL    --azure-project NAME          (default project kinhin-e2e)
                             --azure-pool NAME             (default pool kinhin-e2e)

Anything not given as an option is prompted for.
EOF
    exit "${1:-2}"
}

dry=0
secrets=1
rotate=0
gh_repo=RabinApps/kinhin
forges=""
bk_org="" bk_cluster=kinhin-e2e
bb_workspace="" bb_repo=kinhin-e2e
az_org="" az_project=kinhin-e2e az_pool=kinhin-e2e

while (( $# )); do
    case "$1" in
        buildkite|bitbucket|azure) forges="$forges $1" ;;
        all) forges=" buildkite bitbucket azure" ;;
        --dry-run) dry=1 ;;
        --no-secrets) secrets=0 ;;
        --rotate) rotate=1 ;;
        --repo|--buildkite-org|--buildkite-cluster|--bitbucket-workspace|--bitbucket-repo|--azure-org|--azure-project|--azure-pool)
            (( $# >= 2 )) || { echo "$1 needs a value" >&2; usage; }
            case "$1" in
                --repo) gh_repo=$2 ;;
                --buildkite-org) bk_org=$2 ;;
                --buildkite-cluster) bk_cluster=$2 ;;
                --bitbucket-workspace) bb_workspace=$2 ;;
                --bitbucket-repo) bb_repo=$2 ;;
                --azure-org) az_org=$2 ;;
                --azure-project) az_project=$2 ;;
                --azure-pool) az_pool=$2 ;;
            esac
            shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
    shift
done
[[ -n $forges ]] || usage

command -v curl >/dev/null || die "curl not found"
command -v jq >/dev/null || die "jq not found (brew install jq)"
if (( secrets && ! dry )); then
    command -v gh >/dev/null || die "gh not found (brew install gh), or pass --no-secrets"
    gh auth status >/dev/null 2>&1 || die "gh is not logged in; run 'gh auth login', or pass --no-secrets"
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# --- prompts ---------------------------------------------------------------------------------------------

# ask VAR "question" [default]: a visible prompt. Keeps a value already given as an option; --dry-run takes the
# default or a placeholder.
ask() {
    local var=$1 question=$2 default=${3-} reply
    [[ -z ${!var} ]] || return 0
    if (( dry )); then
        printf -v "$var" '%s' "${default:-example}"
        return 0
    fi
    [[ -t 0 ]] || die "$question: pass it as an option; there is no terminal to ask on"
    read -r -p "$question${default:+ [$default]}: " reply || die "$question: no input"
    printf -v "$var" '%s' "${reply:-$default}"
    [[ -n ${!var} ]] || die "$question: a value is required"
}

# ask_secret VAR "what": a hidden prompt. --dry-run takes a placeholder.
ask_secret() {
    local var=$1 what=$2 reply
    if (( dry )); then
        printf -v "$var" '%s' "dry-run-token"
        return 0
    fi
    [[ -t 0 ]] || die "$what: needs a terminal for the hidden prompt"
    read -r -s -p "$what (hidden): " reply || die "$what: no input"
    echo
    [[ -n $reply ]] || die "$what: a value is required"
    printf -v "$var" '%s' "$reply"
}

# valid VALUE REGEX "what": names go straight into URLs, so keep them to a safe alphabet.
valid() { [[ $1 =~ $2 ]] || die "$3 '$1' is not valid (allowed: $2)"; }

# --- http ------------------------------------------------------------------------------------------------

AUTH=""
HTTP_STATUS=""
HTTP_BODY=""

# api METHOD URL [curl args...]: one call with $AUTH. The credential goes to curl as a config on stdin so it never
# shows in `ps`. Sets HTTP_STATUS and HTTP_BODY; a non-2xx answer is the caller's to judge.
api() {
    local method=$1 url=$2
    shift 2
    if (( dry )); then
        say "[dry-run] $method $url"
        (( $# )) && printf '    %s\n' "$*"
        # A lookup finds nothing, so a dry run walks the create path of every step.
        if [[ $method == GET ]]; then HTTP_STATUS=404; else HTTP_STATUS=000; fi
        HTTP_BODY='{}'
        return 0
    fi
    HTTP_STATUS="$({ printf 'header = "Authorization: %s"\n' "$AUTH" 2>/dev/null || true; } |
        curl -sS --tlsv1.2 --max-time 60 -o "$body_file" -w '%{http_code}' -X "$method" -K - "$@" "$url")" ||
        die "$method $url: curl failed"
    HTTP_BODY="$(cat "$body_file")"
}

api_json() { # METHOD URL JSON
    local method=$1 url=$2 json=$3
    api "$method" "$url" -H 'Content-Type: application/json' --data "$json"
}

# jqr FILTER: read HTTP_BODY, printing nothing when it is not JSON (a rejected PAT answers with an HTML page).
jqr() { printf '%s' "$HTTP_BODY" | jq -r "$@" 2>/dev/null || true; }

brief() { printf '%s' "$HTTP_BODY" | head -c 300 | tr '\n' ' '; }

# expect "STATUS|STATUS" "what": stop unless the last call answered one of these.
expect() {
    (( dry )) && return 0
    [[ $HTTP_STATUS =~ ^($1)$ ]] || die "$2: HTTP $HTTP_STATUS $(brief)"
}

# check_azure_org ORG_URL PROBE_PATH: tell "no such organization" and "PAT rejected" apart from a missing project.
# The probe must be a read the PAT's own scopes cover: Projects - List needs Project and Team (Read), which the
# narrow e2e PAT does not have to carry.
check_azure_org() {
    api GET "$1$2"
    (( dry )) && return 0
    case "$HTTP_STATUS" in
        200) ;;
        404) die "no Azure DevOps organization answers at $1; the name is the part after dev.azure.com/ in your browser" ;;
        203 | 302 | 401 | 403) die "the PAT was rejected by $1 (HTTP $HTTP_STATUS); check its organization, expiry and scopes" ;;
        *) die "cannot reach $1: HTTP $HTTP_STATUS $(brief)" ;;
    esac
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# --- secrets ---------------------------------------------------------------------------------------------

set_secret() { # NAME VALUE
    if (( dry )); then
        say "[dry-run] gh secret set $1 --repo $gh_repo   (value not shown)"
    elif (( ! secrets )); then
        say "not stored (--no-secrets): $1"
    else
        printf '%s' "$2" | gh secret set "$1" --repo "$gh_repo" >/dev/null
        say "stored secret $1"
    fi
}

set_variable() { # NAME VALUE ('' removes it)
    if (( dry )); then
        say "[dry-run] gh variable $([[ -n $2 ]] && echo "set $1=$2" || echo "delete $1") --repo $gh_repo"
    elif (( ! secrets )); then
        say "not stored (--no-secrets): $1"
    elif [[ -n $2 ]]; then
        gh variable set "$1" --repo "$gh_repo" --body "$2" >/dev/null
        say "stored variable $1=$2"
    else
        gh variable delete "$1" --repo "$gh_repo" >/dev/null 2>&1 || true
        say "no expiry recorded: removed $1 if it was set"
    fi
}

# set_expiry FORGE [required]: ask when the new token expires and record it, so e2e-token-expiry.yml can warn
# before it does. A token that always expires (Bitbucket, Azure DevOps) must have a date.
set_expiry() {
    local date=""
    if (( dry )); then
        date=2099-01-01
    elif (( secrets )); then
        [[ -t 0 ]] || die "token expiry: needs a terminal to ask on"
        read -r -p "When does this token expire? (YYYY-MM-DD, blank if never): " date || die "token expiry: no input"
    fi
    [[ -n $date || -z ${2-} || $dry == 1 || $secrets == 0 ]] || die "this token expires, so a date is required; the reminder workflow reads it"
    [[ -z $date || $date =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || die "'$date' is not a YYYY-MM-DD date"
    set_variable "KINHIN_E2E_${1}_TOKEN_EXPIRES" "$date"
}

# --- buildkite -------------------------------------------------------------------------------------------

buildkite() {
    say "Buildkite"
    ask bk_org "Buildkite organization slug"
    ask bk_cluster "Cluster name" kinhin-e2e
    valid "$bk_org" '^[a-z0-9-]+$' "organization slug"
    valid "$bk_cluster" '^[A-Za-z0-9._-]+$' "cluster name"

    cat <<EOF

Create a REST API access token at https://buildkite.com/user/api-access-tokens for only this organization, with the
scopes read_agents, write_agents, read_builds, write_builds, read_clusters, write_clusters, read_pipelines and
write_pipelines. It provisions the cluster here (not with --rotate) and is then the secret the lane uses.

EOF
    local token
    ask_secret token "Buildkite API token"
    AUTH="Bearer $token"
    local api_base="https://api.buildkite.com/v2/organizations/$bk_org"

    api GET https://api.buildkite.com/v2/access-token
    expect 200 "the token was rejected"
    if (( ! dry )); then
        local scope missing=""
        for scope in read_agents write_agents read_builds write_builds read_clusters write_clusters \
            read_pipelines write_pipelines; do
            [[ $(jqr --arg s "$scope" '[.scopes[]? | select(. == $s)] | length') == 1 ]] || missing="$missing $scope"
        done
        [[ -z $missing ]] || die "the token lacks:$missing"
    fi

    api GET "$api_base/clusters"
    expect 200 "cannot list the clusters of $bk_org"
    local cluster_id
    cluster_id="$(jqr --arg n "$bk_cluster" '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase) or .id == $n)][0].id // empty')"
    if [[ -n $cluster_id ]]; then
        say "cluster $bk_cluster exists"
    else
        (( ! rotate || dry )) || die "cluster $bk_cluster does not exist; run without --rotate to create it"
        say "creating cluster $bk_cluster"
        api_json POST "$api_base/clusters" "$(jq -cn --arg n "$bk_cluster" '{name: $n, description: "kinhin e2e fixture"}')"
        expect "200|201" "cannot create the cluster"
        cluster_id="$(jqr '.id // empty')"
        (( dry )) && cluster_id="DRY-RUN-CLUSTER-ID"
        [[ -n $cluster_id ]] || die "the cluster was created but the answer has no id: $(brief)"
    fi

    api GET "$api_base/clusters/$cluster_id/queues"
    expect 200 "cannot list the queues of $bk_cluster"
    if [[ $(jqr '[.[]? | select(.key == "kinhin")] | length') == 1 ]]; then
        say "queue kinhin exists"
    else
        (( ! rotate || dry )) || die "queue kinhin does not exist; run without --rotate to create it"
        say "creating the self-hosted queue kinhin"
        api_json POST "$api_base/clusters/$cluster_id/queues" '{"key":"kinhin","description":"kinhin e2e fixture"}'
        expect "200|201" "cannot create the queue"
    fi

    api GET "$api_base/clusters/$cluster_id/queues"
    expect 200 "cannot list the queues of $bk_cluster"
    (( dry )) || [[ $(jqr '[.[]? | select(.key == "kinhin")] | length') == 1 ]] || die "queue kinhin is still missing"
    say "Buildkite ready: $bk_org/$bk_cluster"

    set_expiry BUILDKITE # first, so a mistyped date stops the run before any secret changes
    set_secret KINHIN_E2E_BUILDKITE_TOKEN "$token"
    (( rotate )) || set_secret KINHIN_E2E_BUILDKITE_SCOPE "$bk_org/$bk_cluster"
}

# --- bitbucket -------------------------------------------------------------------------------------------

bitbucket_provision() { # API_BASE: the repository, its first commit, Pipelines on
    local api_base=$1
    cat <<EOF

Creating a repository needs more than the e2e token can do. Create an Atlassian API token (Account settings >
Security > Create API token with scopes, app: Bitbucket) with the repository and pipeline scopes, including admin
for both: read:/write:/admin:repository:bitbucket and read:/write:/admin:pipeline:bitbucket (turning Pipelines on
needs admin:pipeline; Bitbucket answers a token without it with a misleading 404). It is used here only and is never
stored; revoke it afterwards. App passwords no longer work.

EOF
    local bootstrap
    ask_secret bootstrap "Bitbucket bootstrap API token"
    AUTH="Bearer $bootstrap"

    api GET "$api_base"
    if [[ $HTTP_STATUS == 404 ]]; then
        say "creating the private repository $bb_workspace/$bb_repo"
        api_json POST "$api_base" '{"scm":"git","is_private":true,"description":"kinhin e2e fixture"}'
        expect "200|201" "cannot create the repository (needs the admin:repository:bitbucket scope)"
    else
        expect 200 "cannot read $bb_workspace/$bb_repo"
        say "repository exists"
    fi

    # A new repository can name a main branch before it has any commit, so look for an actual branch.
    api GET "$api_base/refs/branches?pagelen=1"
    expect 200 "cannot list the branches of $bb_workspace/$bb_repo"
    if [[ $(jqr '.values | length') -gt 0 ]]; then
        say "the repository already has a commit"
    else
        say "committing a README so the main branch exists"
        api POST "$api_base/src" \
            --data-urlencode "README.md=# kinhin e2e fixture
Throwaway repository for kinhin's end-to-end suite. The suite owns bitbucket-pipelines.yml." \
            --data-urlencode "message=Initial commit" --data-urlencode "branch=main"
        expect "200|201" "cannot make the first commit"
    fi

    api_json PUT "$api_base/pipelines_config" '{"enabled":true}'
    if (( ! dry )) && [[ ! $HTTP_STATUS =~ ^(200|201)$ ]]; then
        warn "could not enable Pipelines (HTTP $HTTP_STATUS: $(brief))"
        warn "needs admin:pipeline:bitbucket on the bootstrap token; or turn it on in Repository settings > Pipelines > Settings"
        warn "the fixture also turns Pipelines on at the start of each run, so check that works with the repository access token"
    else
        say "Pipelines enabled"
    fi
}

bitbucket() {
    say "Bitbucket Cloud"
    ask bb_workspace "Bitbucket workspace slug"
    ask bb_repo "Repository slug" kinhin-e2e
    valid "$bb_workspace" '^[a-z0-9._-]+$' "workspace slug"
    valid "$bb_repo" '^[a-z0-9._-]+$' "repository slug"
    local api_base="https://api.bitbucket.org/2.0/repositories/$bb_workspace/$bb_repo"

    if (( rotate )); then
        say "rotating the repository access token only (--rotate)"
    else
        bitbucket_provision "$api_base"
    fi

    cat <<EOF

Now create the narrow e2e token. In https://bitbucket.org/$bb_workspace/$bb_repo/admin/access-tokens choose
Create repository access token, tick Repositories: Write, Pipelines: Read and Write, Runners: Read and Write, and
set a short expiry. Repository access tokens may need a paid plan or trial.

EOF
    local token
    ask_secret token "Bitbucket repository access token"
    AUTH="Bearer $token"

    api GET "$api_base"
    expect 200 "the repository access token cannot read $bb_workspace/$bb_repo"
    [[ -n $(jqr '.mainbranch.name // empty') || $dry == 1 ]] || die "the repository answered without a main branch"
    api GET "$api_base/pipelines-config/runners"
    expect 200 "the token cannot list runners (needs the Runners scopes)"
    say "Bitbucket ready: $bb_workspace/$bb_repo"

    set_expiry BITBUCKET required # first, so a mistyped date stops the run before any secret changes
    set_secret KINHIN_E2E_BITBUCKET_TOKEN "$token"
    (( rotate )) || set_secret KINHIN_E2E_BITBUCKET_SCOPE "$bb_workspace/$bb_repo"
}

# --- azure devops ----------------------------------------------------------------------------------------

azure_provision() { # ORG_URL PROJECT_URL REPO_NAME: the project, its commit, the pool and its queue
    local org_url=$1 project_url=$2 repo_name=$3 v="api-version=7.1"
    cat <<EOF

Creating a project and pool needs a broader PAT than the e2e one. Create it at $org_url/_usersSettings/tokens
for this organization with a short expiry and: Project and Team (Read, write & manage), Agent Pools (Read & manage),
Code (Read & write), Pipeline Resources (Use & manage). It is used here only and is never stored; revoke it
afterwards. The account that owns it becomes Administrator of the pool, and the e2e PAT must belong to the same user.

EOF
    local bootstrap
    ask_secret bootstrap "Azure DevOps bootstrap PAT"
    AUTH="Basic $(b64 ":$bootstrap")"

    check_azure_org "$org_url" "/_apis/projects?\$top=1&$v"
    api GET "$org_url/_apis/projects/$az_project?$v"
    local created=0
    if [[ $HTTP_STATUS == 404 ]]; then
        say "creating the private project $az_project"
        api_json POST "$org_url/_apis/projects?$v" "$(jq -cn --arg n "$az_project" '{
            name: $n, description: "kinhin e2e fixture", visibility: "private",
            capabilities: {
                versioncontrol: {sourceControlType: "Git"},
                processTemplate: {templateTypeId: "6b724908-ef14-45cf-84f8-768b5384da45"}}}')"
        expect "200|201|202" "cannot create the project"
        local op_url status
        op_url="$(jqr '.url // empty')"
        if (( ! dry )); then
            [[ -n $op_url ]] || die "the project was queued but the answer has no operation url: $(brief)"
            for _ in $(seq 1 40); do
                api GET "$op_url"
                status="$(jqr '.status // empty')"
                case "$status" in
                    succeeded) break ;;
                    failed | cancelled) die "creating the project $status: $(jqr '.resultMessage // .detailedMessage // empty')" ;;
                esac
                sleep 3
            done
            [[ $status == succeeded ]] || die "creating the project did not finish in 2 minutes; re-run to continue"
        fi
        created=1
    else
        expect 200 "cannot read the project $az_project (a 203 or an HTML answer means the PAT is rejected)"
        say "project exists"
    fi

    # A new project's repository can take a few seconds to show up.
    local tries=1 repo_id="" default_branch=""
    (( created && ! dry )) && tries=10
    for _ in $(seq 1 "$tries"); do
        api GET "$project_url/_apis/git/repositories/$repo_name?$v"
        [[ $HTTP_STATUS == 404 && $created == 1 ]] || break
        sleep 3
    done
    expect 200 "cannot read the repository $repo_name"
    repo_id="$(jqr '.id // empty')"
    default_branch="$(jqr '.defaultBranch // empty')"
    [[ -n $repo_id || $dry == 1 ]] || die "the repository answer has no id: $(brief)"
    if [[ -n $default_branch ]]; then
        say "repository $repo_name already has a default branch ($default_branch)"
    else
        say "committing a README so the repository has a default branch"
        api_json POST "$project_url/_apis/git/repositories/${repo_id:-REPO-ID}/pushes?$v" '{
            "refUpdates": [{"name": "refs/heads/main", "oldObjectId": "0000000000000000000000000000000000000000"}],
            "commits": [{"comment": "Initial commit", "changes": [{"changeType": "add",
                "item": {"path": "/README.md"},
                "newContent": {"content": "# kinhin e2e fixture\nThrowaway repository for the kinhin end-to-end suite.\n", "contentType": "rawtext"}}]}]}'
        expect "200|201" "cannot make the first commit"
    fi

    api GET "$org_url/_apis/distributedtask/pools?poolName=$az_pool&$v"
    expect 200 "cannot list agent pools"
    local pool_id
    pool_id="$(jqr '.value[0].id // empty')"
    if [[ -n $pool_id ]]; then
        say "agent pool $az_pool exists"
    else
        say "creating the self-hosted agent pool $az_pool"
        api_json POST "$org_url/_apis/distributedtask/pools?$v" \
            "$(jq -cn --arg n "$az_pool" '{name: $n, autoProvision: true, poolType: "automation"}')"
        expect "200|201" "cannot create the agent pool"
        pool_id="$(jqr '.id // empty')"
        (( dry )) && pool_id=0
        [[ -n $pool_id ]] || die "the pool was created but the answer has no id: $(brief)"
    fi

    # The pool's queue in the project, authorized for all pipelines: the "Grant access permission to all pipelines"
    # box. Without it every run waits for an approval and the lane times out.
    api GET "$project_url/_apis/distributedtask/queues?queueName=$az_pool&$v"
    local queue_id
    queue_id="$(jqr '.value[0].id // empty')"
    if [[ -z $queue_id ]]; then
        say "adding the pool to the project"
        api_json POST "$project_url/_apis/distributedtask/queues?authorizePipelines=true&$v" \
            "$(jq -cn --argjson id "$pool_id" --arg n "$az_pool" '{name: $n, pool: {id: $id}}')"
        expect "200|201" "cannot add the pool to the project"
        queue_id="$(jqr '.id // empty')"
        (( dry )) && queue_id=0
    fi
    if [[ -n $queue_id ]]; then
        api_json PATCH "$project_url/_apis/pipelines/pipelinepermissions/queue/$queue_id?api-version=7.1-preview.1" \
            '{"allPipelines":{"authorized":true}}'
        if (( ! dry )) && [[ ! $HTTP_STATUS =~ ^(200|201)$ ]]; then
            warn "could not authorize the pool for all pipelines (HTTP $HTTP_STATUS); tick 'Grant access permission to all pipelines' on the pool in Organization settings > Agent pools"
        fi
    else
        warn "could not find the pool's queue in the project; add the pool under Project settings > Agent pools"
    fi
}

azure() {
    say "Azure DevOps"
    ask az_org "Azure DevOps organization name or URL"
    ask az_project "Project name" kinhin-e2e
    ask az_pool "Agent pool name" kinhin-e2e
    if [[ $az_org == *://* ]]; then
        valid "$az_org" '^https://[A-Za-z0-9./_:-]+$' "organization URL"
    else
        valid "$az_org" '^[A-Za-z0-9-]+$' "organization name"
    fi
    valid "$az_project" '^[A-Za-z0-9._-]+$' "project name"
    valid "$az_pool" '^[A-Za-z0-9._-]+$' "pool name"
    local org_url=$az_org
    [[ $org_url == *://* ]] || org_url="https://dev.azure.com/$az_org"
    while [[ $org_url == */ ]]; do org_url=${org_url%/}; done
    local v="api-version=7.1"
    local project_url="$org_url/$az_project"
    local repo_name=$az_project # a new project's default repository carries its name

    if (( rotate )); then
        say "rotating the PAT only (--rotate)"
    else
        azure_provision "$org_url" "$project_url" "$repo_name"
    fi

    cat <<EOF

Now create the e2e PAT at $org_url/_usersSettings/tokens, as the same user, with Agent Pools (Read & manage),
Build (Read & execute) and Code (Read & write), plus Project and Team (Read) if creating pipelines is refused
without it. A new organization may also need its free parallel job: https://aka.ms/azpipelines-parallelism-request.

EOF
    local token
    ask_secret token "Azure DevOps e2e PAT"
    AUTH="Basic $(b64 ":$token")"

    check_azure_org "$org_url" "/_apis/distributedtask/pools?poolName=$az_pool&$v"
    expect 200 "the e2e PAT cannot list pools"
    [[ -n $(jqr '.value[0].id // empty') || $dry == 1 ]] || die "the e2e PAT cannot see the pool $az_pool"
    api GET "$project_url/_apis/git/repositories/$repo_name?$v"
    expect 200 "the e2e PAT cannot read the repository $repo_name"
    say "Azure DevOps ready: $org_url / $az_project / $az_pool"

    set_expiry AZURE required # first, so a mistyped date stops the run before any secret changes
    set_secret KINHIN_E2E_AZURE_TOKEN "$token"
    if (( ! rotate )); then
        set_secret KINHIN_E2E_AZURE_ORG "$az_org"
        set_secret KINHIN_E2E_AZURE_PROJECT "$az_project"
        set_secret KINHIN_E2E_AZURE_POOL "$az_pool"
    fi
}

# --- main ------------------------------------------------------------------------------------------------

for forge in $forges; do
    "$forge"
    echo
done

if (( secrets && ! dry )); then
    say "secrets on $gh_repo:"
    gh secret list --repo "$gh_repo" | grep KINHIN_E2E_ || true
fi
cat <<EOF
Next, once the kinhin-e2e Mac is registered (docs/e2e-testing.md):

  gh workflow run e2e.yml --repo $gh_repo -f tier=local

EOF
if (( rotate )); then
    echo "Revoke the token you replaced."
else
    case "$forges" in
        *bitbucket* | *azure*) echo "Revoke the one-time bootstrap credentials now, and the e2e tokens when you finish a test pass." ;;
        *) echo "Revoke the e2e token when you finish a test pass." ;;
    esac
fi
