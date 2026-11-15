# 🌕 luatools-moon

## Install

Do not run this fork's `install.sh`: it is the upstream 32-bit installer and
stops with an error here. This fork is the LuaTools plugin tree that
[moon64](https://github.com/KadirBerkpolat1/moon64) installs on Steam's 64-bit
client. Install with:

```bash
curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash
```

---

Linux port of the `ltsteamplugin` plugin, built exclusively for the [slsteam-moon](https://github.com/swwayps/slsteam-moon) project. It serves as an integration layer that fetches manifest packs and installs them for slsteam-moon to consume natively on Linux.

## Credits

Upstream:

- [piqseu](https://github.com/piqseu/ltsteamplugin) — the `ltsteamplugin`
  release line this fork tracks. Originally by
  [madoiscool](https://github.com/madoiscool/ltsteamplugin).

Reference material:

- [StarWarsK & geovanygrdt](https://github.com/Star123451/LuaToolsLinux) —
  prior Linux port.
- [Millennium](https://github.com/SteamClientHomebrew/Millennium) —
  Steam client modding framework.
- [CloudRedirect](https://github.com/Selectively11/CloudRedirect) by
  Selectively11 — optional cloud saves for unowned games.

## Support

Open an issue: https://github.com/swwayps/luatools-moon/issues

## Uninstall

Want to remove everything? Run:

```bash
curl -fsSL https://raw.githubusercontent.com/swwayps/luatools-moon/main/uninstall.sh | bash
```
