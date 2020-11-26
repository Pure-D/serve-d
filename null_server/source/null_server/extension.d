module null_server.extension;

import served.lsp.protocol;

alias members = __traits(derivedMembers, null_server.extension);

InitializeResult initialize(InitializeParams params)
{
	return InitializeResult(ServerCapabilities.init);
}