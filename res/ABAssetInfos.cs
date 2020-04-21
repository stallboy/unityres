using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Config;

namespace BuildSystem
{
    public class ABAssetinfos
    {
        public class AssetInfo
        {
            public string asset;

            public bool isMarked;
            public bool isNeedMark;

            public int memSize;
            public int canSaveMemSize;
            public int containingABCount;

            public HashSet<string> containingABs = new HashSet<string>();
            public HashSet<string> directContainingAssets = new HashSet<string>();
        }

        private class Comparer : IComparer<AssetInfo>
        {
            public int Compare(AssetInfo x, AssetInfo y)
            {
                int save = y.canSaveMemSize - x.canSaveMemSize;
                if (save != 0)
                {
                    return save;
                }

                int mem = y.memSize - x.memSize;
                if (mem != 0)
                {
                    return mem;
                }

                return string.Compare(x.asset, y.asset, StringComparison.Ordinal);
            }
        }

        public static IComparer<AssetInfo> assetinfoCmp = new Comparer();

        public List<AssetInfo> sortedAllAssetInfos = new List<AssetInfo>();

        public Dictionary<string, AssetInfo> allAssetInfoMap = new Dictionary<string, AssetInfo>();
        public long canSaveSum;
        public long allSize;
        public string canSavePercent;
        public string sumStr;

        public void Add(AssetInfo ai)
        {
            sortedAllAssetInfos.Add(ai);
            allAssetInfoMap.Add(ai.asset, ai);
        }

        public bool Get(string path, out AssetInfo ai)
        {
            return allAssetInfoMap.TryGetValue(path, out ai);
        }

        public void Sort()
        {
            sortedAllAssetInfos.Sort(assetinfoCmp);
        }

        public void Sum()
        {
            canSaveSum = 0;
            allSize = 0;
            foreach (var ai in sortedAllAssetInfos)
            {
                canSaveSum = canSaveSum + ai.canSaveMemSize;
                allSize = allSize + ai.memSize*ai.containingABCount;
                //Debug.Log(ai.asset + "," + ai.canSaveMemSize + "," + ai.memSize + "," + ai.containingABCount + "," + canSaveSum + "," + allSize);
            }
            double percent = (double) canSaveSum/allSize;
            canSavePercent = percent.ToString("0.00");
            sumStr = "cnt=" + sortedAllAssetInfos.Count + "," +
                     "cansave/all=" + ToolUtils.readableSize(canSaveSum) + "/" +
                     ToolUtils.readableSize(allSize) + "=" +
                     canSavePercent;
        }

        public void SaveToCsv(string saveFn)
        {
            using (var texter = new StreamWriter(saveFn, false)) //no bom
            {
                var header1 = new[]
                {
                    "asset",
                    "isMarked",
                    "allMem=" + ToolUtils.readableSize(allSize),
                    "canSave=" + ToolUtils.readableSize(canSaveSum),
                    "percent=" + canSavePercent,
                    "count=" + sortedAllAssetInfos.Count,
                    ""
                };

                texter.WriteLine(string.Join(",", header1));

                var header2 = new[]
                {
                    "asset", "isMarked", "memSize", "canSaveMemSize", "count", "containingABs", "directContainingAssets"
                };
                texter.WriteLine(string.Join(",", header2));

                foreach (var ai in sortedAllAssetInfos)
                {
                    var line = new[]
                    {
                        ai.asset,
                        ai.isMarked ? "1" : "0",
                        ai.memSize.ToString(),
                        ai.canSaveMemSize.ToString(),
                        ai.containingABCount.ToString(),
                        string.Join(":", ai.containingABs.ToArray()),
                        string.Join(":", ai.directContainingAssets.ToArray()),
                    };

                    texter.WriteLine(string.Join(",", line));
                }
            }
        }

        public void LoadFromCsv(string saveFn)
        {
            sortedAllAssetInfos.Clear();
            allAssetInfoMap.Clear();
            var lines = CSV.Parse(new StreamReader(saveFn));
            for (int i = 2; i < lines.Count; i++)
            {
                var line = lines[i];
                var ai = new AssetInfo
                {
                    asset = line[0],
                    isMarked = line[1].Equals("1"),
                    memSize = int.Parse(line[2]),
                    canSaveMemSize = int.Parse(line[3]),
                    containingABCount = int.Parse(line[4]),
                    containingABs = new HashSet<string>(line[5].Split(':')),
                    directContainingAssets = new HashSet<string>(line[6].Split(':'))
                };
                Add(ai);
            }
            Sum();
        }
    }
}