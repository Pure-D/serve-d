module app;

static import null_server.extension;

import served.serverbase;

mixin LanguageServerRouter!(null_server.extension) server;

int main(string[] args)
{
	return server.run() ? 0 : 1;
}
