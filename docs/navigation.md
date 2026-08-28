# Navigation and content map

Opal navigation is organized around user tasks. Integrations are capabilities
and filters, not permanent primary destinations.

| Task | Desktop route | Web route | Content/capabilities |
| --- | --- | --- | --- |
| Home | `home` | `home` | Continue watching, recommendations, calendar |
| Search | `search` | `search` | Universal installed-source search |
| Browse | `browse` | `browse` | Source-filtered catalogs |
| Watching | `watching` | `watch` | Up next and saved library |
| Downloads | `downloads` | `act` | Direct and torrent transfers |
| Queue | `queue` | `act` | Playback queue |
| History | `history` | `act` | Recent playback |
| Playing | `player` | `np` | Active media and transport controls |
| Assistant | `assistant` | `ai` | Optional local/cloud assistant |
| Plugins | `plugins` | `setup` | Source and connector setup |
| Settings | `settings` | `setup` | Application and access settings |
| Logs | `system` | `logs` | Diagnostics |

Browse presents one source selector. Built-in and configured capabilities may
include Movies & TV, YouTube, Live TV, anime, podcasts, radio, music, comics,
Web/RSS, Jellyfin, Plex, Audiobookshelf, OPDS, novels, visual novels, and Asian
drama. Their configuration belongs under Plugins or Settings. Ctrl/Cmd+K keeps
direct command-palette access for keyboard users.

`DrawerTab` remains only as a compatibility identifier used by feature commands
and the legacy shell. New product navigation must use `router.Route`; new
connectors must register as Browse/Search capabilities rather than adding a
top-level route or source tab.
