# Using serve-d with Sublime Text
---

Requirments:
    - LSP Package: https://lsp.sublimetext.io/


Client Configuration:

```json
{
	"clients": {
		"serve-d": {
			"enabled": true,
			"command": ["C:/Users/MY_NAME_HERE/AppData/Roaming/code-d/bin/serve-d.exe"],
			"selector": "source.d",
			"settings": {
				"d.dcdServerPath": "C:/Users/MY_NAME_HERE/AppData/Roaming/code-d/bin/dcd-server.exe",
				"d.dcdClientPath": "C:/Users/MY_NAME_HERE/AppData/Roaming/code-d/bin/dcd-client.exe",

				// optional settings
				"d.servedReleaseChannel": "nightly",
				"d.aggressiveUpdate": false,
				"d.manyProjectsAction": "load",
				"d.enableAutoComplete": true,
				"d.completeNoDupes": true,
			}
		}
	}
}
```
