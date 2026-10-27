// macOS app extensions enter Foundation's extension host, not NSApplicationMain.
extern int NSExtensionMain(int argc, char *argv[]);
int main(int argc, char *argv[]) { return NSExtensionMain(argc, argv); }
