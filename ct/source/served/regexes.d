module served.regexes;

import std.regex;

static immutable importRegex = ctRegex!(`import\s+(?:[a-zA-Z_]+\s*=\s*)?([a-zA-Z_]\w*(?:\.\w*[a-zA-Z_]\w*)*)?(\s*\:\s*(?:[a-zA-Z_,\s=]*(?://.*?[\r\n]|/\*.*?\*/|/\+.*?\+/)?)+)?;?`);
static immutable regexQuoteChars = "['\"`]?";
static immutable undefinedIdentifier = ctRegex!(`^undefined identifier ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `(?:, did you mean .*? ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `\?)?$`);
static immutable undefinedTemplate = ctRegex!(
		`template ` ~ regexQuoteChars ~ `(\w+)` ~ regexQuoteChars ~ ` is not defined`);
static immutable noProperty = ctRegex!(`^no property ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `(?: for type ` ~ regexQuoteChars ~ `.*?` ~ regexQuoteChars ~ `)?$`);
static immutable moduleRegex = ctRegex!(
		`(?<!//.*)\bmodule\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
static immutable whitespace = ctRegex!(`\s*`);

static immutable ddocGetsRegex = ctRegex!`^[Gg]et([^a-z]|$)`;
static immutable ddocSetsRegex = ctRegex!`^[Ss]et([^a-z]|$)`;
static immutable ddocIsRegex = ctRegex!`^[Ii]s([^a-z]|$)`;
static immutable identifierRegex = ctRegex!`[a-zA-Z_][a-zA-Z0-9_]*`;
