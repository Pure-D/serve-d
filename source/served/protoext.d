module served.protoext;

import served.protocol;

import std.json;

struct AddImportParams
{
	TextDocumentIdentifier textDocument;
	string name;
	int location;
	bool insertOutermost = true;
}

struct UpdateSettingParams
{
	string section;
	JSONValue value;
	bool global;
}
