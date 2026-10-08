# Running kinhin on a rented Mac

Run a kinhin fleet on a Mac you rent by the month instead of one on your desk: a colocated Mac mini
or a bare-metal cloud Mac. This is also how a team or consultancy can run CI for someone else: one
dedicated Mac per customer, their own forge token, no shared hardware.

[← Back to README](../README.md)

kinhin is a single-owner tool: one Mac, one set of forge tokens, one operator. Renting a Mac does
not change that. You get a machine without having to own or host one, and everything else on this
page is the normal [install and setup](install.md) with a few remote-specific steps.

## Choosing a host

Any provider that gives you a dedicated Apple Silicon Mac with a GUI login session works. Compare
current prices and terms on each provider's own page; they change often.

| Option                   | Billing shape                  | Notes                                                                 |
| ------------------------ | ------------------------------ | --------------------------------------------------------------------- |
| Mac mini colocation/rent | Monthly                        | Cheapest per month for a standing fleet (for example MacStadium)      |
| Apple Silicon bare metal | Monthly or hourly, by provider | Check the provider's minimum lease; Apple's license sets one for hosted Macs |
| AWS EC2 Mac              | Per hour, with a 24 h minimum  | Dedicated host; fine for bursts, costly for an always-on fleet        |

Sizing is the same as for a Mac on your desk: see [Hardware requirements & sizing](hardware.md).
Remember the macOS ceiling: **two concurrent macOS VMs per Mac**, whatever the hardware. More
macOS concurrency means more Macs (see [running on multiple Macs](scaling.md#running-on-multiple-macs))
or `runners_per_vm`.

::: warning One customer per Mac
Every job runs in its own VM, but all VMs share one host and, by default, one virtual network (see
[Security](security.md)). Do not put two unrelated customers' repositories on the same Mac. If you
resell this setup, give each customer a dedicated Mac and have them create the forge token.
Check the host provider's and Apple's terms on resale and minimum lease periods before you price
anything.
:::

## Bootstrap

SSH in as the Mac's admin user and run the bootstrap script from a checkout of this repository:

```bash
ssh admin@your-mac 'bash -s' < scripts/bootstrap-rented-mac.sh
```

It checks the host (Apple Silicon, macOS 15+, Homebrew), installs Tart and kinhin if they are
missing, creates a starter `config.yaml`, and prints the remaining steps. It is idempotent, and it
never touches a token.

## Configure and authenticate

Edit `~/Library/Application Support/Kinhin/config.yaml`: set the `accounts:` entry for the
customer's forge and the labels their jobs request. Then, in an SSH session on the Mac:

```bash
# Over plain ssh the login Keychain is locked; unlock it for this session
security unlock-keychain ~/Library/Keychains/login.keychain-db

kinhin auth set        # prompts for the token; use --gitlab, --gitea, ... for other forges
kinhin doctor          # prerequisites, and how many VMs this Mac can hold
kinhin image prepare   # once; bakes the runner base image
```

Have the customer create a token with the minimum scope their forge needs (see
[Forge support](forges.md)) and type it themselves, or hand it over through a channel you already
trust. Do not put it in a script argument, an environment variable or a shell history.

## Keep it running unattended

`kinhin daemon install` installs a LaunchAgent, which runs in the user's GUI session. On a headless
rented Mac that means:

- Turn on **automatic login** for the admin user (System Settings → Users & Groups), so the session,
  and the login Keychain with it, exists after a reboot. Providers typically document this for their
  machines.
- Keep FileVault off, or you will need to unlock the disk by hand after every reboot. Weigh that
  against the data on the Mac: it holds only a forge token and throwaway VMs.
- Install the daemon from that session (a VNC or Screen Sharing login works), then confirm
  with `kinhin status` over SSH.

```bash
kinhin daemon install
kinhin status
```

Finally, dispatch a workflow whose `runs-on` labels match the config and watch it with
`kinhin watch`.

## What this does not give you

- No multi-tenant control plane, remote API or billing. Each Mac is operated like any other kinhin
  host, over SSH.
- No GitHub App or JIT registration yet; runners register with a PAT and `--ephemeral` (see the
  [GitHub notes](forges/github.md)).
- Only GitHub Actions with Tart VMs and apple/container has been tested for real; see the [beta roadmap](beta-roadmap.md).
