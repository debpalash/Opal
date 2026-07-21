# DMCA & Content Takedown Policy

Opal is an open-source media **player and aggregator**. The project:

- **hosts no media.** There is no Opal server, index, or CDN. The software runs
  on the user's machine and connects only to sources the user configures.
- **ships no scrapers in the core.** Content sources are external plugins the
  user chooses to install (see [`CONTENT_POLICY.md`](CONTENT_POLICY.md)).
- distributes **source code and build artifacts only** through this repository
  and its GitHub Releases.

That said, we take valid infringement notices seriously in the two places we
actually control:

## 1. This repository (code, docs, assets, releases)

If you believe something *in this repository itself* infringes your copyright,
use [GitHub's DMCA process](https://docs.github.com/en/site-policy/content-removal-policies/dmca-takedown-policy),
which governs content hosted on GitHub. You may also open a private report to
the maintainers first — see the contact section below; we usually respond
faster than a formal takedown resolves.

## 2. Plugins: default posture and the registry

### 2.1 Nothing is installed or enabled by default

As distributed — whether built from source or downloaded as a release
artifact — Opal ships with **no third-party content source installed,
enabled, or pre-configured**. The application contains general-purpose
*connector* code (protocol clients for BitTorrent, HTTP, Stremio-compatible
add-ons, and similar open protocols); a connector without an endpoint reaches
nothing. The software is, and is intended to be, a general-purpose tool
capable of substantial non-infringing uses — the demonstrations in this
repository use openly licensed works (Big Buck Bunny, Sintel; © Blender
Foundation, CC-BY 3.0) precisely because that is the intended mode of use.

### 2.2 Installation is an affirmative, user-directed act

A content source becomes operative **only** upon the user's own volitional,
per-plugin action:

1. the user opens the Plugins panel and explicitly selects **Install** on a
   specific entry;
2. only then is that entry's endpoint descriptor retrieved, at the user's
   direction, and written to the **user's own configuration directory**
   (`~/.config/opal/plugins/`) on the user's machine;
3. the action is individually reversible (**Uninstall**), and no plugin is
   bundled, selected by default, recommended by the software, or silently
   installed, re-enabled, or updated into an enabled state by any automatic
   process.

The maintainers accordingly do not determine — and have no means of knowing —
which sources, if any, exist in a given installation. Which endpoints are
present on a user's machine is the product of that user's deliberate choices,
and responsibility for the lawfulness of those choices rests with the user
(see [`CONTENT_POLICY.md`](CONTENT_POLICY.md)).

### 2.3 The registry (`plugins-manifest.json`) and removal on notice

The repository contains a community-maintained registry whose entries are
**pointers** — names, versions, and endpoint URLs — comparable to a directory
listing. The registry hosts no content, proxies no traffic, and yields the
maintainers no revenue from any listed source. Its entries are severable: the
removal of any entry has no effect on the software itself.

If a registry entry points at a source that infringes your rights:

- Send a notice (see requirements below) identifying the **registry entry**
  and the **copyrighted work** concerned.
- On a valid notice, maintainers will remove the entry and note the removal in
  the commit message. Removal takes effect for all users at their next
  registry refresh; already-installed copies reside on users' machines, which
  the maintainers cannot and do not reach into.
- Entries removed for infringement are not re-added without evidence the
  source is authorized. Repeatedly infringing sources are permanently
  excluded from the registry.

## Notice requirements

To be actionable (per 17 U.S.C. § 512(c)(3)), a notice must include:

1. Identification of the copyrighted work claimed to be infringed.
2. Identification of the material claimed to be infringing (file path, manifest
   entry, or release artifact) with enough detail for us to locate it.
3. Your contact information (name, address, email).
4. A statement of good-faith belief that the use is not authorized by the
   copyright owner, its agent, or the law.
5. A statement, under penalty of perjury, that the information is accurate and
   that you are the owner or authorized to act for the owner.
6. Your physical or electronic signature.

## Counter-notices

If your contribution was removed and you believe the removal was mistaken, you
may submit a counter-notice with the elements required by § 512(g)(3). For
repository content, GitHub's counter-notice process applies.

## Contact

Open a GitHub issue titled `[DMCA]` for non-confidential matters, or contact
the maintainer through the email listed on the repository owner's GitHub
profile for confidential notices. Please don't use the issue tracker for
notices containing personal information.

## What this policy is not

Opal cannot police what users do with a general-purpose player, and this policy
creates no duty to monitor. Users are responsible for complying with the law in
their jurisdiction — see [`CONTENT_POLICY.md`](CONTENT_POLICY.md) and the
disclaimer in [`README.md`](README.md).
