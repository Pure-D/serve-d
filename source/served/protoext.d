module served.protoext;

import served.protocol;

struct AddImportParams
{
	TextDocumentIdentifier textDocument;
	string name;
	int location;
	bool insertOutermost = true;
}
