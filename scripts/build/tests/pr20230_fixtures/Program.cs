// Copyright (c) Contributors to the Open 3D Engine Project.
// SPDX-License-Identifier: Apache-2.0 OR MIT
// Test double only: validates the PowerShell harness state machine.
// It does NOT exercise O3DE's actual AssetProcessor or material builders.

using System;
using System.IO;
using System.Linq;
using System.Text;

static class FakeAssetProcessor
{
    private static string GetArg(string[] args, string name)
    {
        string prefix = "--" + name + "=";
        string? arg = args.FirstOrDefault(x => x.StartsWith(prefix, StringComparison.Ordinal));
        if (arg is null)
        {
            throw new ArgumentException("Missing " + prefix);
        }
        return arg.Substring(prefix.Length).Trim('"');
    }

    private static int Main(string[] args)
    {
        try
        {
            bool zeroAnalysis = args.Any(x => x.Contains("zeroAnalysisMode", StringComparison.OrdinalIgnoreCase));

            string project = GetArg(args, "project-path");
            string cache = GetArg(args, "project-cache-path");
            string source = Path.Combine(project, "Assets", "pr20230_cache_probe.mp4");
            string target = Path.Combine(cache, "pc", "assets", "pr20230_cache_probe.mp4");
            string material = Path.Combine(cache, "Intermediate Assets", "materials", "types",
                "standardpbr_mainpipeline_forwardpass_standardlighting.azsl");

            Directory.CreateDirectory(cache);
            string marker = Path.Combine(cache, "pr20230-fake-run-number.txt");
            int run = File.Exists(marker) ? int.Parse(File.ReadAllText(marker)) + 1 : 1;
            File.WriteAllText(marker, run.ToString());

            string mode = Environment.GetEnvironmentVariable("PR20230_FAKE_AP_MODE") ?? "pass";
            if (mode == "slow-timeout" && run == 1)
            {
                System.Threading.Thread.Sleep(4500);
            }

            if (!(mode == "initial-product-missing" && run == 1) &&
                !(mode == "missing-copy" && run >= 2) &&
                !(zeroAnalysis && mode != "baseline-regenerates"))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(source, target, true);
                if (mode == "bad-copy" && run >= 2)
                {
                    File.WriteAllText(target, "deliberately corrupted copy-job output");
                }
            }

            if (!(mode == "missing-azsl" && run >= 2))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(material)!);
                string payload = (mode == "bad-azsl" && run >= 2)
                    ? "deliberately corrupted Material Type Builder output"
                    : "// deterministic material intermediate for harness tests";
                File.WriteAllText(material, payload, Encoding.UTF8);
            }

            Console.WriteLine($"FakeAP run={run} mode={mode} zeroAnalysis={zeroAnalysis} product={File.Exists(target)} material={File.Exists(material)}");
            if (mode == "nonzero-but-restored")
            {
                Console.Error.WriteLine("Injected unrelated AssetProcessor job failure");
                return 7;
            }
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Fake AssetProcessor exception: " + ex);
            return 8;
        }
    }
}
