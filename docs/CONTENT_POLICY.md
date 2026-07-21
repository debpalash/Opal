# Content, Copyright, and Source Policy

This document describes how Opal relates to media content, third-party sources,
plugins, and copyright. It also explains how to report material you believe
infringes your rights.

Opal's binary and configuration directory are `opal` (the legacy internal name was `zigzag`; on-disk data migrates automatically).
References to "Opal," "the project," "the software," and "the application" all
refer to the same work.

## 1. What Opal Is

**Opal is a media player and aggregator/client. It is not a content host.**

Opal is a native, local-first desktop application that:

- Plays local and network media (via libmpv).
- Acts as a **client** to services and protocols that the user configures
  (for example Jellyfin servers, TMDB metadata, Stremio add-ons, RSS feeds,
  torrent indexers, and similar).
- Aggregates and presents results from **third-party sources** so they can be
  browsed and played through a single interface.

Opal itself **hosts no media, stores no copyrighted content, indexes no
copyrighted catalogs, and distributes no infringing files.** It contains no
media library of its own. Every piece of content that Opal can locate, stream,
or download originates from a third party that the user or a user-installed
plugin has chosen to connect to.

In short: Opal is a lens through which other people's services are viewed. The
content, and responsibility for that content, lives with those services and
with the user who chooses to access them — not with Opal.

## 2. Responsible Use

**You are solely responsible for how you use Opal and for the content you
access through it.**

- You must comply with all applicable copyright, licensing, and computer-use
  laws in your jurisdiction.
- You should only stream, download, cache, or otherwise access content that you
  have the legal right to access — for example content you own, content you are
  licensed to view, public-domain works, or material made available under terms
  that permit your use.
- The availability of a source inside Opal is **not** a representation that the
  content offered by that source is lawful for you to access.

**The project does not condone, encourage, promote, or facilitate copyright
infringement or piracy.** Opal is provided as a general-purpose media runtime
for lawful, personal use. Any use of Opal to infringe copyright or to violate
the terms of service of a third-party provider is against the spirit and intent
of the project and is undertaken entirely at the user's own risk and
responsibility.

## 3. Third-Party Sources, Indexers, and Scrapers

Opal can connect to a wide range of third-party sources. These may include
metadata providers, media servers, add-on protocols, public indexers, torrent
trackers, and scraper-based connectors.

Regarding all such third-party sources:

- They are **operated by independent third parties**. They are **not affiliated
  with, endorsed by, controlled by, or sponsored by Opal or its maintainers.**
- Their content, accuracy, availability, safety, and **legality vary by region**
  and may change at any time without notice.
- The BitTorrent protocol, where used, connects the user's device to a public
  peer-to-peer network (including the DHT and public trackers) and exposes the
  user's IP address to other peers in the swarm. Using peer-to-peer networks may
  carry legal and privacy implications that differ by jurisdiction.
- Whether it is lawful for a given user to connect to, query, or download from
  any particular source is **the user's responsibility to determine.**

Opal provides the technical ability to connect to sources the user configures or
enables. It does not vouch for any of them.

## 4. Plugins

Opal supports a third-party plugin system. Plugins are installed by the user into
their own configuration directory and extend Opal with additional content
sources.

Users must understand the following before installing any plugin:

- **Plugins are third-party software, not part of Opal.** They are not written,
  reviewed, vetted, audited, signed, or endorsed by the Opal maintainers.
- **Plugins run as code on your machine.** Depending on plugin type, this may
  include running arbitrary native executables or scripts with the privileges of
  your user account. Sandboxing of plugins is limited and, for some plugin types,
  effectively absent. **Install and run plugins entirely at your own risk.**
- The maintainers of Opal are **not responsible for the behavior, content,
  safety, security, privacy practices, or legality of any plugin** or of the
  sources a plugin connects to.
- **Plugins must not be used to infringe copyright** or to access content the
  user has no legal right to access. Distributing a plugin whose primary purpose
  is to facilitate infringement is not a supported or sanctioned use of the
  plugin system.

Only install plugins from sources you trust, and review what a plugin does
before enabling it.

## 5. DMCA and Takedown Requests

**Opal hosts no media content.** Because the project stores and distributes no
copyrighted media, takedown requests aimed at content that appears *through*
Opal must be directed to the **third-party source** that actually hosts or
distributes that content — Opal has no ability to remove material it neither
hosts nor controls.

However, if you are a copyright owner (or an agent authorized to act on their
behalf) and you believe that **the Opal project's own repository or
distribution** contains material that infringes your copyright, you may submit a
takedown request.

**DMCA / Takedown contact:** see [`DMCA.md`](DMCA.md) — open a GitHub issue
titled `[DMCA]` for non-confidential matters, or use the maintainer email on
the repository owner's GitHub profile for confidential notices.

To help us act quickly, please include the following in your notice:

1. Your contact information (name, address, email, and telephone number).
2. Identification of the copyrighted work you claim has been infringed.
3. Identification of the specific material in the project's repository or
   distribution that you claim is infringing, with enough detail (such as file
   paths, commit hashes, or URLs) for us to locate it.
4. A statement that you have a good-faith belief that the identified use is not
   authorized by the copyright owner, its agent, or the law.
5. A statement, made under penalty of perjury, that the information in your
   notice is accurate and that you are the copyright owner or are authorized to
   act on the owner's behalf.
6. Your physical or electronic signature.

We will review properly submitted notices in good faith and, where appropriate,
remove or disable access to the identified material in the project's own
repository.

Please note: requests to "remove a movie," "block a torrent," "take down a
stream," or otherwise remove third-party content that merely appears through
Opal cannot be actioned by us, because that content is not hosted, stored, or
controlled by the project. Such requests should be directed to the host of the
content in question.

## 6. No Warranty

Opal is **free software provided "as is," without warranty of any kind**, express
or implied, including but not limited to the warranties of merchantability,
fitness for a particular purpose, non-infringement, and title. The entire risk
as to the quality, performance, and lawful use of the software rests with the
user.

To the maximum extent permitted by applicable law, the maintainers and
contributors of Opal shall not be liable for any claim, damages, or other
liability — whether in an action of contract, tort, or otherwise — arising from,
out of, or in connection with the software, its use, the sources it connects to,
or the plugins a user installs.

Opal is intended for **personal, lawful use only.** By using Opal, you accept
sole responsibility for ensuring that your use complies with the laws applicable
to you.

---

*This document explains the project's position on content and copyright. It is
not legal advice. If you are unsure whether a particular use is lawful in your
jurisdiction, consult a qualified attorney.*
