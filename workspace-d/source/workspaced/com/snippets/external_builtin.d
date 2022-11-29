/// List of dependency-based snippets for packages outside phobos and druntime.
module workspaced.com.snippets.external_builtin;

import workspaced.com.snippets;

static immutable PlainSnippet[] builtinVibeHttpSnippets = [
	{
		levels: [SnippetLevel.method],
		shortcut: "viberouter",
		title: "vibe.d router",
		documentation: "Basic router instance code with GET / path.\n\nReference: https://vibed.org/api/vibe.http.router/URLRouter",
		snippet: "auto ${1:router} = new URLRouter();\n${1:router}.get(\"/\", &${2:index});",
		imports: ["vibe.http.router"]
	},
	{
		levels: [SnippetLevel.method],
		shortcut: "vibeserver",
		title: "vibe.d HTTP server",
		documentation: "Basic vibe.d HTTP server startup code.\n\nReference: https://vibed.org/api/vibe.http.server/",
		snippet: "auto ${3:settings} = new HTTPServerSettings();\n"
			~ "${3:settings}.port = ${1:3000};\n"
			~ "${3:settings}.bindAddresses = ${2:[\"::1\", \"127.0.0.1\"]};\n"
			~ "\n"
			~ "auto ${4:router} = new URLRouter();\n"
			~ "${4:router}.get(\"/\", &${5:index});\n"
			~ "\n"
			~ "listenHTTP(${3:settings}, ${4:router});\n",
		imports: ["vibe.http.server", "vibe.http.router"]
	},
	{
		levels: [SnippetLevel.method],
		shortcut: "vibeget",
		title: "vibe.d GET request",
		documentation: "Code for a simple low-level async GET request.\n\nReference: https://vibed.org/api/vibe.http.client/requestHTTP",
		snippet: "requestHTTP(URL(\"$1\"), null, (scope HTTPClientResponse res) {\n"
			~ "\t${2:// TODO: check res.statusCode and read response into parent scope variables.}\n"
			~ "});",
		imports: ["vibe.http.client"]
	},
	{
		levels: [SnippetLevel.method],
		shortcut: "viberequest",
		title: "vibe.d HTTP request (POST/GET/PUT/...)",
		documentation: "Code for a simple low-level async HTTP request.\n\nReference: https://vibed.org/api/vibe.http.client/requestHTTP",
		snippet: "requestHTTP(URL(\"$1\"), (scope HTTPClientRequest req) {\n"
			~ "\treq.method = HTTPMethod.${2:POST};\n"
			~ "\t${3:// TODO: write request body}\n"
			~ "}, (scope HTTPClientResponse res) {\n"
			~ "\t${4:// TODO: check res.statusCode and read response into parent scope variables.}\n"
			~ "});",
		imports: ["vibe.http.client"]
	},
	{
		levels: [SnippetLevel.method],
		shortcut: "vibegetstring",
		title: "vibe.d GET request into string",
		documentation: "Code for a simple async GET request storing the full response body in a string.\n\nReference: https://vibed.org/api/vibe.http.client/requestHTTP",
		snippet: "string ${1:text};\n"
			~ "requestHTTP(URL(\"$2\"), null, (scope HTTPClientResponse res) {\n"
			~ "\t${3:// TODO: check res.statusCode}\n"
			~ "\t${1:text} = res.bodyReader.readAllUTF8();\n"
			~ "});",
		imports: ["vibe.http.client"]
	},
	{
		levels: [SnippetLevel.method],
		shortcut: "vibegetjson",
		title: "vibe.d GET request as json",
		documentation: "Code for a simple async GET request storing the full response body in a string.\n\nReference: https://vibed.org/api/vibe.http.client/requestHTTP",
		snippet: "Json ${1:json};\n"
			~ "requestHTTP(URL(\"$2\"), null, (scope HTTPClientResponse res) {\n"
			~ "\t${3:// TODO: check res.statusCode}\n"
			~ "\t${1:json} = res.readJson(); // TODO: possibly want to add .deserializeJson!T\n"
			~ "});",
		imports: ["vibe.data.json", "vibe.http.client"]
	},
];

static immutable PlainSnippet[] builtinMirSerdeSnippets = [
	{
		levels: [SnippetLevel.type, SnippetLevel.mixinTemplate],
		shortcut: "deserializeFromIon",
		title: "mir-ion deserializeFromIon",
		documentation: "Custom mir-ion struct deserializion code.\n\n"
			~ "**Note:** this is an advanced construct and you probably don't "
			~ "need to use this unless you have very specific needs. You can "
			~ "probably use a proxy instead.",
		snippet: "@safe pure scope\n"
			~ "IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value) {\n"
			~ "\timport mir.deser.ion : deserializeIon;\n"
			~ "\timport mir.ion.type_code : IonTypeCode;\n"
			~ "\n"
			~ "\tif (value.descriptor.type == IonTypeCode.struct_) {\n"
			~ "\t\t${1:this.impl} = deserializeIon!${2:DeserializeType}(symbolTable, value);$0\n"
			~ "\t} else {\n"
			~ "\t\treturn ionException(IonErrorCode.expectedStructValue);\n"
			~ "\t}\n"
			~ "\treturn null;\n"
			~ "}\n",
		imports: ["mir.ion.exception", "mir.ion.value"]
	},
	{
		levels: [SnippetLevel.type, SnippetLevel.mixinTemplate],
		shortcut: "serializeIon",
		title: "mir-ion serialize",
		documentation: "Custom mir-ion struct serializion code.\n\n"
			~ "**Note:** a proxy might achieve the same thing if you just want to "
			~ "serialize a single member.",
		snippet: "void serialize(S)(scope ref S serializer) const @safe pure scope {\n"
			~ "\timport mir.ser : serializeValue;\n"
			~ "\n"
			~ "\tserializeValue(serializer, ${1:this.impl});$0\n"
			~ "}\n"
	},
];

static immutable DependencySnippets[] builtinDependencySnippets = [
	DependencySnippets(["vibe-d:http"], builtinVibeHttpSnippets),
	DependencySnippets(["mir-ion"], builtinMirSerdeSnippets),
];
