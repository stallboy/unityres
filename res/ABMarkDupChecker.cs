using System.Collections.Generic;
using UnityEditor;
using UnityEngine;

namespace BuildSystem
{
    public class ABMarkDupChecker
    {
        private static Dictionary<string, string> _markedAsset2Bundle;
        private static Dictionary<string, ABAssetinfos.AssetInfo> _allAssetInfos;
        private static ABAssetinfos _assetInfos;

        private static bool IsMarked(string asset)
        {
            return _markedAsset2Bundle.ContainsKey(asset);
        }

        //这里的细节是得用直接依赖AssetDatabase.GetDependencies(thisAsset, false))，来计算重复率，不能使用全部依赖，
        //比如a，b，c 3个asset，a包含b，b包含c。。
        //a，b打成了A，B2个Bundle，那么c这个asset，的containingABs只能包含B，不能包含A。
        private static void CollectUnmarkedAsset(string thisAsset, string bundle)
        {
            foreach (var asset in AssetDatabase.GetDependencies(thisAsset, false))
            {
                if (!asset.EndsWith(".cs") && !IsMarked(asset))
                {
                    ABAssetinfos.AssetInfo res;
                    if (_allAssetInfos.TryGetValue(asset, out res))
                    {
                        res.containingABs.Add(bundle);
                        res.directContainingAssets.Add(thisAsset);
                    }
                    else
                    {
                        res = new ABAssetinfos.AssetInfo {asset = asset, isMarked = false};
                        res.containingABs.Add(bundle);
                        res.directContainingAssets.Add(thisAsset);
                        _allAssetInfos.Add(asset, res);
                    }
                    CollectUnmarkedAsset(asset, bundle);
                }
            }
        }

        private static long CalcSize(string asset)
        {
            if (asset.EndsWith(".unity"))
            {
                return 0;
            }
            var objs = AssetDatabase.LoadAllAssetsAtPath(asset);
            long allsize = 0;
            foreach (var obj in objs)
            {
                if (obj != null)
                {
                    var size = UnityEngine.Profiling.Profiler.GetRuntimeMemorySizeLong(obj);
                    allsize += size;

                    if (obj is GameObject || obj is Component)
                    {
                    }
                    else
                    {
                        Resources.UnloadAsset(obj);
                    }
                }
                else
                {
                    Debug.LogError(asset + " load=null");
                }
            }
            return allsize;
        }


        public static void CheckDuplicate(string dupcsvfn)
        {
            _markedAsset2Bundle = new Dictionary<string, string>();
            foreach (var bundle in AssetDatabase.GetAllAssetBundleNames())
            {
                foreach (var asset in AssetDatabase.GetAssetPathsFromAssetBundle(bundle))
                {
                    _markedAsset2Bundle.Add(asset, bundle);
                }
            }

            Debug.Log("marked asset count=" + _markedAsset2Bundle.Count);
            _allAssetInfos = new Dictionary<string, ABAssetinfos.AssetInfo>();
            foreach (var kv in _markedAsset2Bundle)
            {
                CollectUnmarkedAsset(kv.Key, kv.Value);
            }

            foreach (var kv in _markedAsset2Bundle)
            {
                var ai = new ABAssetinfos.AssetInfo {asset = kv.Key, isMarked = true};
                ai.containingABs.Add(kv.Value);
                _allAssetInfos.Add(kv.Key, ai);
            }
            Debug.Log("all asset count=" + _allAssetInfos.Count);


            _assetInfos = new ABAssetinfos();
            foreach (var kv in _allAssetInfos)
            {
                var ai = kv.Value;
                ai.memSize = (int) CalcSize(kv.Key);
                ai.containingABCount = ai.containingABs.Count;
                ai.canSaveMemSize = ai.memSize*(ai.containingABCount - 1);
                _assetInfos.Add(ai);
            }

            _assetInfos.Sort();
            _assetInfos.Sum();

            Resources.UnloadUnusedAssets();


            Debug.Log(_assetInfos.sumStr);

            _assetInfos.SaveToCsv(dupcsvfn);
            Debug.Log("save to " + dupcsvfn);
        }
    }
}