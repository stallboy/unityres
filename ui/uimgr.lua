--------------------------------------------------------
--- UI分层管理系统：
--- 1，world （world，worldnpc，worldme）
--- 2，main                               替代互斥本层
--- 3，dashboard                          激活时隐藏2层，
--- 4，module                             激活时隐藏1-3层，回退互斥4，5层
--- 5，tool （tool，tool2，tool3）
--- 6，dialog （dialog，dialoginectype）  激活时隐藏1-5，7层/3-5层
--- 7，tip
--- 8，guide
--- 9，system (同步预先加载好)
--- 10，loading
--- 11, lockscreen

local uimgr = {}

function uimgr.initLayers(layers)

    layers.main:exc({
        exc_panelbyclose = { layers.main }
    })

    layers.main1:exc({
    })

    layers.dashboard:exc({
        exc_layer = { layers.main, layers.main1 }
    })

    layers.module:exc({
        exc_layer = {
            layers.world, layers.worldnpc,
            layers.main, layers.main1,
            layers.dashboard
        },
        exc_panelbystack = {
            layers.module,
            layers.tool, layers.tool2, layers.tool3
        }
    })

    layers.dialog:exc({
        exc_layer = {
            layers.world,
            layers.main, layers.main1,
            layers.dashboard,
            layers.module,
            layers.tool, layers.tool2, layers.tool3,
            layers.tip
        },
        exc_panelbyclose = { layers.dialog }
    })

    layers.dialoginectype:exc({
        exc_layer = {
            layers.main, layers.main1,
            layers.dashboard,
            layers.module,
            layers.tool, layers.tool2, layers.tool3,
        }
    })
end

return uimgr
