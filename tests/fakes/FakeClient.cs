using System;
using System.IO;
using System.Text;

sealed class FakeClient
{
    static int Main(string[] args)
    {
        string log = Environment.GetEnvironmentVariable("FAKE_CLIENT_LOG");
        if (!string.IsNullOrEmpty(log))
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < args.Length; i++)
            {
                if (i > 0) sb.Append('\n');
                sb.Append(args[i]);
            }
            File.AppendAllText(log, sb.ToString() + "\n---\n", new UTF8Encoding(false));
        }

        bool dump = false;
        bool hasCol = false;
        string result = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--single-transaction") dump = true;
            if (args[i] == "--column-statistics=0") hasCol = true;
            if (args[i].StartsWith("--result-file=")) result = args[i].Substring(14);
        }

        if (dump)
        {
            string reject = Environment.GetEnvironmentVariable("FAKE_REJECT_COLUMN_STATISTICS");
            string marker = Environment.GetEnvironmentVariable("FAKE_REJECT_MARKER");
            if (reject == "1" && hasCol && !string.IsNullOrEmpty(marker) && !File.Exists(marker))
            {
                string markerDir = Path.GetDirectoryName(marker);
                if (!string.IsNullOrEmpty(markerDir) && !Directory.Exists(markerDir)) Directory.CreateDirectory(markerDir);
                File.WriteAllText(marker, "rejected", new UTF8Encoding(false));
                Console.Error.WriteLine("mysqldump: unknown option '--column-statistics'");
                return 2;
            }
            if (string.IsNullOrEmpty(result))
            {
                Console.Error.WriteLine("missing --result-file");
                return 2;
            }
            string dir = Path.GetDirectoryName(result);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(result, "-- fake dump\n", new UTF8Encoding(false));
            return 0;
        }

        MemoryStream ms = new MemoryStream();
        using (Stream input = Console.OpenStandardInput())
        {
            input.CopyTo(ms);
        }
        byte[] stdin = ms.ToArray();
        if (Environment.GetEnvironmentVariable("FAKE_ECHO") == "1")
        {
            using (Stream output = Console.OpenStandardOutput())
            {
                output.Write(stdin, 0, stdin.Length);
            }
            return 0;
        }

        string text = new UTF8Encoding(false).GetString(stdin);
        if (text.IndexOf("VERSION()", StringComparison.Ordinal) >= 0)
        {
            byte[] body = new UTF8Encoding(false).GetBytes("version\tlocal_infile\tsql_mode\n8.4.7\t0\tSTRICT\n");
            using (Stream output = Console.OpenStandardOutput())
            {
                output.Write(body, 0, body.Length);
            }
            return 0;
        }

        Console.Error.WriteLine("fake mysql: unhandled sql");
        return 1;
    }
}
