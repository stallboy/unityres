# unityres
resource manager for unity slua 

## 初始化

### res.init(editormode, abpath2assetinfo)

* editormode 如果设置true，则使用同步调用AssetDatabase.LoadAssetAtPath 

* abpath2assetinfo 由assetinfo.csv直接生成。当加载有依赖项的assetbundle时方便cache依赖的assetbundle。

### res.load_manifest(assetinfo, callback)

* assetinfo 格式为 { assetpath: xx, abpath: xx, type: xx, location: xx, cache: xx }，应该是从assetinfo.csv中读取，而assetinfo.csv由打包程序生成。

* 其中type 可能为 { assetbundle = 1, asset = 2, prefab = 3 }； location 可能为 { www = 1, resources = 2 }；

* 其中cache 为Cache类的一个instance，里面实现了lru。

* 约定所有assetinfo的assetpath不为nil，且assetinfo.csv以assetpath作为primary key，当type为asetbundle时assetpath==abpath

* callback 参数为 (err, asset) err为nil时代表成功。


## 加载

### future = res.load(assetinfo, callback)

* 返回一个future对象，可调用future.cancel()。这样就保证这个回调不会被调用。

## 释放

### res.free(assetinfo)

1. 如果这份资源还有其他load，则在assetinfo.cache.loaded中；

2. 如果没有其他load了但刚调用完free，会在assetinfo.cache.cached中等待lru；

3. 这样再等待一段时间，可能会被lru出去，cache中不再持有。


## res.wwwloader

### res.wwwloader.thread 

* 实现了对WWW的资源设限。

* 默认为5， 也就是说最多存在5个WWW，当然你可以在res.init完之后更改此值

### future = res.wwwloader.load(path, callback)

* path 为WWW的参数url

* callback 参数为(err, www)

* 返回future, 可调用future.cancel()。这样就保证这个回调不会被调用。
