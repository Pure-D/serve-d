module served.protoext;

import served.protocol;

import std.json;
import painlessjson;

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

struct DubDependency
{
	string name;
	@SerializedName("version")
	string version_;
	string path;
	string description;
	string homepage;
	const(string)[] authors;
	string copyright;
	string license;
	const(string)[] subPackages;
	bool hasDependencies;
	bool root;
}

struct InstallRequest
{
	string name;
	@SerializedName("version")
	string version_;
}
