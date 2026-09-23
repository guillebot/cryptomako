using CryptoMako.Vault;

return await MainAsync(args);

static async Task<int> MainAsync(string[] args)
{
    if (args.Length == 0 || args[0] is "-h" or "--help")
    {
        PrintHelp();
        return args.Length == 0 ? 2 : 0;
    }

    try
    {
        return args[0] switch
        {
            "unlock" => CmdUnlock(ParseOpts(args.AsSpan(1))),
            "ls" => await CmdLsAsync(ParseOpts(args.AsSpan(1))),
            "cat" => await CmdCatAsync(ParseOpts(args.AsSpan(1))),
            _ => Fail(2, $"unknown command: {args[0]}"),
        };
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
        return Fail(1, Sanitize(ex.Message));
    }
}

static int CmdUnlock(Opts o)
{
    if (o.Local is null) return Fail(2, "--local DIR required until S3 unlock is wired");
    var password = RequirePassword(o.PasswordEnv);
    using var session = VaultSession.UnlockLocal(o.Local, password);
    Console.WriteLine($"format={session.Metadata.Format}");
    Console.WriteLine($"cipherCombo={session.Metadata.CipherCombo}");
    Console.WriteLine($"shorteningThreshold={session.Metadata.ShorteningThreshold}");
    Console.WriteLine($"root={session.RootPath}");
    return 0;
}

static async Task<int> CmdLsAsync(Opts o)
{
    if (o.Local is null) return Fail(2, "--local DIR required");
    var password = RequirePassword(o.PasswordEnv);
    await using var session = VaultSession.UnlockLocal(o.Local, password);
    foreach (var e in await session.ListAsync(o.Path, o.Recursive))
        Console.WriteLine(e);
    return 0;
}

static async Task<int> CmdCatAsync(Opts o)
{
    if (o.Local is null) return Fail(2, "--local DIR required");
    if (o.CatPath is null) return Fail(2, "cat requires a cleartext path");
    var password = RequirePassword(o.PasswordEnv);
    await using var session = VaultSession.UnlockLocal(o.Local, password);
    var bytes = await session.CatAsync(o.CatPath);
    await Console.OpenStandardOutput().WriteAsync(bytes);
    return 0;
}

static Opts ParseOpts(ReadOnlySpan<string> args)
{
    string? local = null;
    string passwordEnv = "CRYPTOMAKO_PASSWORD";
    string path = "/";
    bool recursive = false;
    string? catPath = null;

    for (var i = 0; i < args.Length; i++)
    {
        var a = args[i];
        switch (a)
        {
            case "--local":
                local = NeedValue(args, ref i, a);
                break;
            case "--password-env":
                passwordEnv = NeedValue(args, ref i, a);
                break;
            case "--path":
                path = NeedValue(args, ref i, a);
                break;
            case "-R":
            case "--recursive":
                recursive = true;
                break;
            case "-h":
            case "--help":
                break;
            default:
                if (a.StartsWith('-'))
                    throw new ArgumentException($"unknown flag: {a}");
                catPath ??= a;
                break;
        }
    }

    return new Opts(local, passwordEnv, path, recursive, catPath);
}

static string NeedValue(ReadOnlySpan<string> args, ref int i, string flag)
{
    if (i + 1 >= args.Length) throw new ArgumentException($"missing value for {flag}");
    return args[++i];
}

static string RequirePassword(string envName)
{
    var password = Environment.GetEnvironmentVariable(envName);
    if (string.IsNullOrEmpty(password))
        throw new InvalidOperationException($"Set {envName} (never pass the password on argv).");
    return password;
}

static string Sanitize(string message) => message.Replace('\n', ' ').Replace('\r', ' ');

static int Fail(int code, string message)
{
    Console.Error.WriteLine($"error: {message}");
    return code;
}

static void PrintHelp()
{
    Console.WriteLine("""
        cryptomako — CryptoMako Windows CLI (Cryptomator format 8)

        Usage:
          cryptomako unlock --local DIR
          cryptomako ls --local DIR [--path /] [-R]
          cryptomako cat --local DIR <cleartext-path>

        Password: env CRYPTOMAKO_PASSWORD (override with --password-env NAME). Never argv.
        """);
}

sealed record Opts(string? Local, string PasswordEnv, string Path, bool Recursive, string? CatPath);
