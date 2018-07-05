module served.translate;

import std.conv;
import std.string;

alias Translation = string[string];

private Translation[string] translations;

shared static this()
{
	//dfmt off
	translations = [
		"en" : parseTranslation!(import("en.txt")),
		"de" : parseTranslation!(import("de.txt")),
		"fr" : parseTranslation!(import("fr.txt")),
		"ja" : parseTranslation!(import("ja.txt"))
	];
	//dfmt on
}

private Translation parseTranslation(string s)()
{
	Translation tr;
	foreach (line; s.splitLines)
		if (line.length && line[0] != '#')
		{
			auto colon = line.indexOf(':');
			if (colon == -1)
				continue;
			tr[line[0 .. colon].idup] = line[colon + 1 .. $].idup;
		}
	return tr;
}

string currentLanguage = "en";

string translate(string s, Args...)(Args args)
{
	if (currentLanguage !in translations)
		return s;
	auto language = translations[currentLanguage];
	auto val = s in language;
	if (!val)
		val = s in translations["en"];
	if (!val)
		return s;
	string str = *val;
	foreach (i, arg; args)
		str = str.replace("{" ~ i.to!string ~ "}", arg.to!string);
	return str;
}
