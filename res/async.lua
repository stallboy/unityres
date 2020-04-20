local async = {}

function async.parallel(...)
    return async.parallel_list({ ... })
end

local function empty(done)
    done()
end

function async.parallel_list(tasks)
    if #tasks == 0 then
        return empty
    end

    return function(done)
        local cnt = 0
        for _, task in pairs(tasks) do
            task(function()
                cnt = cnt + 1
                if cnt == #tasks then
                    done()
                end
            end)
        end
    end
end

local function serialNext(tasks, idx, done)
    if idx < #tasks then
        tasks[idx](function() serialNext(tasks, idx + 1, done) end)
    else
        tasks[idx](done)
    end
end

function async.serial(...)
    return async.serial_list({ ... })
end

function async.serial_list(tasks)
    if #tasks == 0 then
        return empty
    end
    return function(done)
        serialNext(tasks, 1, done)
    end
end

return async