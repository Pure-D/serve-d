module served.commands.color;

import std.conv;
import std.format;
import std.regex;

import served.types;

static immutable colorRegex = ctRegex!`#([0-9a-fA-F]{2}){3,4}|"#([0-9a-fA-F]{2}){3,4}"`;

@protocolMethod("textDocument/documentColor")
ColorInformation[] provideDocumentColor(DocumentColorParams params)
{
	Document document = documents[params.textDocument.uri];
	if (document.getLanguageId != "dml")
		return null;

	ColorInformation[] ret;

	{
		// if we ever want to make serve-d multi-threaded, want to lock here
		// document.lock();
		// scope (exit)
		// 	document.unlock();

		size_t cacheBytes;
		Position cachePos;
		foreach (match; matchAll(document.rawText, colorRegex))
		{
			const(char)[] text = match.hit;
			if (text[0] == '"')
				text = text[1 .. $ - 1];
			assert(text[0] == '#', "broken regex match");
			text = text[1 .. $];
			assert(text.length == 6 || text.length == 8, "broken regex match");

			TextRange range;
			cachePos = range.start = document.movePositionBytes(cachePos, cacheBytes, cacheBytes = match.pre.length);
			cachePos = range.end = document.movePositionBytes(cachePos, cacheBytes, cacheBytes = match.pre.length + match.hit.length);

			Color color;
			if (text.length == 8)
			{
				color.alpha = text[0 .. 2].to!int(16) / 255.0;
				text = text[2 .. $];
			}
			color.red = text[0 .. 2].to!int(16) / 255.0;
			color.green = text[2 .. 4].to!int(16) / 255.0;
			color.blue = text[4 .. 6].to!int(16) / 255.0;
			ret ~= ColorInformation(range, color);
		}
	}

	return ret;
}

@protocolMethod("textDocument/colorPresentation")
ColorPresentation[] provideColorPresentations(ColorPresentationParams params)
{
	Document document = documents[params.textDocument.uri];
	if (document.getLanguageId != "dml")
		return null;

	// only hex supported
	string hex;
	if (params.color.alpha != 1)
		hex = format!"#%02x%02x%02x%02x"(
			cast(int)(params.color.alpha * 255),
			cast(int)(params.color.red * 255),
			cast(int)(params.color.green * 255),
			cast(int)(params.color.blue * 255)
		);
	else
		hex = format!"#%02x%02x%02x"(
			cast(int)(params.color.red * 255),
			cast(int)(params.color.green * 255),
			cast(int)(params.color.blue * 255)
		);

	return [ColorPresentation(hex)];
}
