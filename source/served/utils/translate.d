module served.utils.translate;

import std.algorithm;
import std.ascii;
import std.conv;
import std.experimental.logger;
import std.string;
import std.traits;

alias Translation = string[string];

private Translation[string] translations;

shared static this()
{
	translations = [
		"en": parseTranslation!(import("en.txt")),
		"de": parseTranslation!(import("de.txt")),
		"fr": parseTranslation!(import("fr.txt")),
		"ja": parseTranslation!(import("ja.txt")),
		"ru": parseTranslation!(import("ru.txt")),
	];
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
	string* val;
	if (auto lang = currentLanguage in translations)
		val = s in *lang;

	if (!val)
		val = s in translations["en"];

	if (!val)
	{
		warningf("No translation for string '%s' for neither english nor selected language %s!",
				s, currentLanguage);
		return s;
	}
	return formatTranslation(*val, args);
}

string formatTranslation(Args...)(string text, Args formatArgs)
{
	static immutable string escapeChars = `{\`;
	ptrdiff_t startIndex = text.indexOfAny(escapeChars);
	string ret = text;
	while (startIndex != -1)
	{
		ptrdiff_t end = startIndex + 1;
		if (text[startIndex] == '{')
		{
			// {plural #<form int> {arg num} {plurals...}}
			if (text[startIndex + 1 .. $].startsWith("plural"))
			{
				size_t length = "{plural".length;
				auto args = text[startIndex + length .. $];

				// strip space & add length
				auto origLength = args.length;
				args = args.stripLeft;
				length += origLength - args.length;

				// strip '#' & add length
				if (!args.startsWith("#"))
					throw new Exception(
							"Malformed plural argument: expected #<form number> to come after {plural");
				args = args[1 .. $];
				length++;

				// parse form number & space & add length
				origLength = args.length;
				auto form = args.parse!int;
				args = args.stripLeft;
				length += origLength - args.length;

				// strip {<argument>} & add length
				origLength = args.length;
				if (!args.startsWith("{"))
					throw new Exception(
							"Malformed plural argument: expected {<argument index>} to come after {plural #form");
				args = args[1 .. $];
				args = args.stripLeft;
				const n = args.parse!int;
				args = args.stripLeft;
				if (!args.startsWith("}"))
					throw new Exception(
							"Malformed plural argument: expected } to come after {plural #<form> {<argument index>");
				args = args[1 .. $];
				args = args.stripLeft;
				length += origLength - args.length;

				int targetIndex;
			ArgIndexSwitch:
				switch (n)
				{
					static foreach (i, arg; formatArgs)
					{
				case i:
						static if (isIntegral!(typeof(arg)))
							targetIndex = resolvePlural(form, cast(int) arg);
						else static if (isSomeString!(typeof(arg)))
							targetIndex = resolvePlural(form, arg.to!int);
						else
							assert(false, "Cannot pluralize based on value of type " ~ typeof(arg).stringof);
						break ArgIndexSwitch;
					}
				default:
					targetIndex = 0;
					break ArgIndexSwitch;
				}

				string insert;
				int argIndex;
				while (args.startsWith("{"))
				{
					origLength = args.length;
					int depth = 1;
					end = 0;
					while (end != -1)
					{
						end = args.indexOfAny("{}", end + 1);
						if (args[end] == '}')
							depth--;
						else if (args[end] == '{')
							depth++;

						if (depth == 0)
							break;
					}
					if (end == -1)
						throw new Exception("Malformed plural: argument " ~ (argIndex + 1)
								.to!string ~ " missing closing '}' character.");
					const arg = formatTranslation(args[1 .. end], formatArgs);

					args = args[end + 1 .. $].stripLeft;
					if (argIndex == 0 || argIndex == targetIndex)
						insert = arg;
					argIndex++;
					length += origLength - args.length;
				}

				if (!args.startsWith("}"))
					throw new Exception("Malformed plural: missing closing '}' character after all arguments");
				args = args[1 .. $];
				length++;

				text = text[0 .. startIndex] ~ insert ~ text[startIndex + length .. $];
				end = startIndex + insert.length;
			}
			else // {arg num}
			{
				end = text.indexOf('}', startIndex);
				if (end == -1)
					break;

				if (text[startIndex + 1 .. end].all!isDigit)
				{
					auto n = text[startIndex + 1 .. end].to!int;
					string insert;
				ArgSwitch:
					switch (n)
					{
						static foreach (i, arg; formatArgs)
						{
					case i:
							insert = arg.to!string;
							break ArgSwitch;
						}
					default:
						insert = null;
						break ArgSwitch;
					}

					text = text[0 .. startIndex] ~ insert ~ text[end + 1 .. $];
					end = startIndex + insert.length;
				}
			}
		}
		else if (text[startIndex] == '\\')
		{
			if (end >= text.length)
				break;
			const c = text[end];
			switch (c)
			{
			case 't':
				text = text[0 .. startIndex] ~ "\t" ~ text[end + 1 .. $];
				break;
			case 'r':
				text = text[0 .. startIndex] ~ "\r" ~ text[end + 1 .. $];
				break;
			case 'n':
				text = text[0 .. startIndex] ~ "\n" ~ text[end + 1 .. $];
				break;
			case '\\':
			case '{':
			default:
				text = text[0 .. startIndex] ~ text[end .. $];
				break;
			}
			end--;
		}
		else
			assert(false, "don't know why did startIndex end up here");

		startIndex = text.indexOfAny(escapeChars, end + 1);
	}
	return text;
}

unittest
{
	assert(formatTranslation("{0} {1}", "hello", "world") == "hello world");

	assert(formatTranslation("DCD is outdated. (target={0}, installed={1})",
			"v1.12.0", "v1.11.1") == "DCD is outdated. (target=v1.12.0, installed=v1.11.1)");
}

unittest
{
	string lit1 = `\n\nthere {plural   #1  {0} {is one item}  {are {0} items}}?`;
	string lit2 = `\n\nthere {plural#1 {0}{is one item} {are {0} items}}?`;
	assert(formatTranslation(lit1, 0) == "\n\nthere are 0 items?", formatTranslation(lit1, 0));
	assert(formatTranslation(lit1, 1) == "\n\nthere is one item?");
	assert(formatTranslation(lit2, 4) == "\n\nthere are 4 items?");
}

/// Implements mozilla's plural forms.
/// See_Also: https://developer.mozilla.org/en-US/docs/Mozilla/Localization/Localization_and_Plurals
/// Returns: the index which plural word to use. For each rule from top to bottom.
int resolvePlural(int form, int n)
{
	switch (form)
	{
		// Asian, Persian, Turkic/Altaic, Thai, Lao
	case 0:
		return 0;
		// Germanic, Finno-Ugric, Language isolate, Latin/Greek, Semitic, Romanic, Vietnamese
	case 1:
		return n == 1 ? 0 : 1;
		// Romanic, Lingala
	case 2:
		return n == 0 || n == 1 ? 0 : 1;
		// Baltic
	case 3:
		if (n % 10 == 0)
			return 0;
		else if (n != 11 && n % 10 == 1)
			return 1;
		else
			return 2;
		// Celtic
	case 4:
		if (n == 1 || n == 11)
			return 0;
		else if (n == 2 || n == 12)
			return 1;
		else if ((n >= 3 && n <= 10) || (n >= 13 && n <= 19))
			return 2;
		else
			return 3;
		// Romanic
	case 5:
		if (n == 1)
			return 0;
		else if ((n % 100) >= 0 && (n % 100) <= 19)
			return 1;
		else
			return 2;
		// Baltic
	case 6:
		if (n != 11 && n % 10 == 1)
			return 0;
		else if (n % 10 == 0 || (n % 100 >= 11 && n % 100 <= 19))
			return 1;
		else
			return 2;
		// Belarusian, Russian, Ukrainian
	case 7:
		// Slavic
	case 19:
		if (n != 11 && n % 10 == 1)
			return 0;
		else if (n != 12 && n != 13 && n != 14 && (n % 10 >= 2 && n % 10 <= 4))
			return 1;
		else
			return 2;
		// Slavic
	case 8:
		if (n == 1)
			return 0;
		else if (n >= 2 && n <= 4)
			return 1;
		else
			return 2;
		// Slavic
	case 9:
		if (n == 1)
			return 0;
		else if (n >= 2 && n <= 4 && !(n >= 12 && n <= 14))
			return 1;
		else
			return 2;
		// Slavic
	case 10:
		if (n % 100 == 1)
			return 0;
		else if (n % 100 == 2)
			return 1;
		else if (n % 100 == 3 || n % 100 == 4)
			return 2;
		else
			return 3;
		// Celtic
	case 11:
		if (n == 1)
			return 0;
		else if (n == 2)
			return 1;
		else if (n >= 3 && n <= 6)
			return 2;
		else if (n >= 7 && n <= 10)
			return 3;
		else
			return 4;
		// Semitic
	case 12:
		if (n == 1)
			return 0;
		else if (n == 2)
			return 1;
		else if (n == 0)
			return 5;
		else
		{
			const d = n % 100;
			if (d >= 0 && d <= 2)
				return 4;
			else if (d >= 3 && d <= 10)
				return 2;
			else
				return 3;
		}
		// Semitic
	case 13:
		if (n == 1)
			return 0;
		else
		{
			const d = n % 100;
			if (d >= 1 && d <= 10)
				return 1;
			else if (d >= 11 && d <= 19)
				return 2;
			else
				return 3;
		}
		// unused
	case 14:
		if (n % 10 == 1)
			return 0;
		else if (n % 10 == 2)
			return 1;
		else
			return 2;
		// Icelandic, Macedonian
	case 15:
		if (n != 11 && n % 10 == 1)
			return 0;
		else
			return 1;
		// Celtic
	case 16:
		const a = n % 10;
		const b = n % 100;
		if (a == 1 && b != 11 && b != 71 && b != 91)
			return 0;
		else if (a == 2 && b != 12 && b != 72 && b != 92)
			return 1;
		else if (a.among!(3, 4, 9) && !b.among!(13, 14, 19, 73, 74, 79, 93, 94, 99))
			return 2;
		else if (n % 1_000_000 == 0)
			return 3;
		else
			return 4;
		// Ecuador indigenous languages
	case 17:
		return (n == 0) ? 0 : 1;
		// Welsh
	case 18:
		switch (n)
		{
		case 0:
			return 0;
		case 1:
			return 1;
		case 2:
			return 2;
		case 3:
			return 3;
		case 6:
			return 4;
		default:
			return 5;
		}
	default:
		throw new Exception("Unknown plural form");
	}
}
