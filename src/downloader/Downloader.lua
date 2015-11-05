require("json")

local M = class("Downloader")

M.LIST_FILE_NAME = "list.txt"

M.STATUS_WAITING = 0
M.STATUS_DOING = 1
M.STATUS_DONE = 2

function M:ctor(directory, maxCacheNum, maxConcurrentNum)
    -- directory 存储目录
    -- maxCacheNum 最多缓存的文件数量
    -- maxConcurrentNum 最大并发数
    self.directory = cc.FileUtils:getInstance():getWritablePath() .. directory .. "/"

    self.maxCacheNum = maxCacheNum
    -- 必须起码是1，否则刚下载完就删除了
    if self.maxCacheNum <= 1 then
        self.maxCacheNum = 1
    end
    self.maxConcurrentNum = maxConcurrentNum

    -- 当前运行数量
    self.concurrentNum = 0
    -- 任务序列号
    self.taskSeqNum = 0
    -- 下载队列 每个元素格式为 {url: url, tasks: [task, task]}
    self.containerQueue = {}

    -- 创建目录，依赖lfs
    -- 如果想要不调用到lfs，就提前把目录建立好
    if not io.exists(self.directory) then
        lfs.mkdir(self.directory)
    end

    -- 文件列表记录
    self.filenameList = self:readFromListFile()
end

function M:execute(url, timeout, succCallback, failCallback, timeoutCallback)
    -- url 下载链接
    -- succCallback 成功回调
    -- failCallback 失败回调
    -- timeoutCallback 超时回调

    self.taskSeqNum = self.taskSeqNum + 1

    local taskID = self.taskSeqNum

    local filename = self:genNameByUrl(url)

    local path = self.directory .. filename

    -- 如果已经下载过了，当然就直接用就好了
    -- 并且不需要再去检测下载，以为不影响下载并发数
    if io.exists(path) then
        -- 延迟一个帧，因为调用方可能还想存下taskID
        self:scheduleScriptFuncOnce(function ()
                succCallback(path)
        end, 0)
        return taskID
    end

    local task = {
        id=taskID,
        succCallback=succCallback,
        failCallback=failCallback,
        timeoutCallback=timeoutCallback,
    }

    local container = self:findDownloadContainer(url)
    if container then
        table.insert(container.tasks, task)
    else
        table.insert(self.containerQueue, {
                filename=filename,  -- 名字用来存在list文件里
                url=url,
                timeout=timeout,
                path=path,
                tasks={task},
                status=self.STATUS_WAITING,
        })
    end

    self:tryDownload()

    return taskID
end

function M:removeTask(taskID)
    -- 通过taskID删除任务，但是已经启动的任务似乎已经没法删除了
    local found = false

    for i, container in ipairs(self.containerQueue) do
        for j, task in ipairs(container.tasks) do
            if task.id == taskID then
                table.remove(container.tasks, j)
                -- 找到就break
                found = true
                break
            end
        end

        if found then
            if #container.tasks == 0 then
                -- 可以删掉了
                table.remove(self.containerQueue, i)
            end

            -- 找到了就退出
            return true
        end
    end

    return false
end

function M:tryDownload()
    local container = self:findFirstWaitingContainer()
    -- 没有的话，就返回就好
    if not container then
        return
    end

    -- 超过最大并发也返回
    if self.concurrentNum >= self.maxConcurrentNum then
        return
    end

    -- 如果已经下载过，就不要再下载
    if io.exists(container.path) then
        for i, task in ipairs(container.tasks) do
            task.succCallback(container.path)
        end
        return
    end

    -- 启动下载
    self:download(container)
end

function M:download(container)

    -- 忘记了这段代码
    container.status = self.STATUS_DOING

    local xhr = cc.XMLHttpRequest:new()
    xhr.responseType = cc.XMLHTTPREQUEST_RESPONSE_BLOB
    xhr:open("GET", container.url)
    xhr.timeout = container.timeout

    -- 因为用XMLHttpRequest自己的timeout回调判断不出来status，404和超时都是0
    local timeoutEntry
    local function innerOnTimeout ()
        xhr:abort()
        self:onDownloadTimeout(container)
    end

    timeoutEntry = self:scheduleScriptFuncOnce(innerOnTimeout, container.timeout)

    local function onReadyStateChange()
        self:unscheduleEntry(timeoutEntry)

        -- print ("status: " .. xhr.status)

        if not (xhr.status>=200 and xhr.status<300) then
            self:onDownloadFail(container, xhr.status)
            return
        end

        -- 有可能这个时候path已经存在了，不过就先还是写吧
        local f = assert(io.open(container.path, "wb"))
        f:write(xhr.response)
        f:close()

        self:onDownloadSucc(container)
    end

    xhr:registerScriptHandler(onReadyStateChange)

    self.concurrentNum = self.concurrentNum + 1
    xhr:send()
end

function M:onContainerDone(container)
    -- 所有回调都要先执行的函数

    self.concurrentNum = self.concurrentNum - 1
    container.status = self.STATUS_DONE
    self:removeContainer(container)

    -- 先启动下一次下载，免得下一个函数里面抛异常
    self:tryDownload()
end

function M:onDownloadSucc(container)
    if container.status == self.STATUS_DONE then
        return
    end
    self:onContainerDone(container)

    -- 删除老文件
    self:addFileToList(container.filename)

    for i, task in ipairs(container.tasks) do
        task.succCallback(container.path)
    end
end

function M:onDownloadFail(container, status)
    if container.status == self.STATUS_DONE then
        return
    end
    self:onContainerDone(container)

    for i, task in ipairs(container.tasks) do
        task.failCallback(status)
    end
end

function M:onDownloadTimeout(container)
    if container.status == self.STATUS_DONE then
        return
    end
    self:onContainerDone(container)

    for i, task in ipairs(container.tasks) do
        task.timeoutCallback()
    end
end

function M:genNameByUrl(url)
    local md5 = require("downloader.md5")
    return md5.sumhexa(url)
end

function M:addFileToList(filename)
    -- 删掉超过个数的文件
    table.insert(self.filenameList, filename)

    while #self.filenameList > self.maxCacheNum do
        -- 删掉最早的那一个
        local to_remove_filename = table.remove(self.filenameList, 1)
        local to_remove_path = self.directory .. to_remove_filename
        os.remove(to_remove_path)
    end

    self:writeToListFile(self.filenameList)
end


-- 仅注册一次
function M:scheduleScriptFuncOnce(callback, interval)
    -- 务必先定义local，否则在回调函数里面认不出来
    local schedEntry
    schedEntry = cc.Director:getInstance():getScheduler():scheduleScriptFunc(
        function (...)
            -- print(string.format("callback: %s, schedEntry: %s", callback, schedEntry))
            cc.Director:getInstance():getScheduler():unscheduleScriptEntry(schedEntry)

            callback(...)
        end,
    interval, false)

    return schedEntry
end

function M:unscheduleEntry(entryID)
    cc.Director:getInstance():getScheduler():unscheduleScriptEntry(entryID)
end

function M:findDownloadContainer(url)
    -- 寻找相同url的container

    for i, container in ipairs(self.containerQueue) do
        if container.url == url then
            return container
        end
    end

    return nil
end

function M:findFirstWaitingContainer()
    -- 寻找还没有处理的第一个container
    for i, container in ipairs(self.containerQueue) do
        -- 没有在处理中
        if container.status == self.STATUS_WAITING then
            return container
        end
    end

    return nil
end

function M:removeContainer(container)
    for i, saved_container in ipairs(self.containerQueue) do
        -- 没有在处理中
        if saved_container == container then
            table.remove(self.containerQueue, i)
            return
        end
    end
end

function M:readFromListFile()
    local path = self.directory .. "/" .. self.LIST_FILE_NAME
    if not io.exists(path) then
        return {}
    end
    
    local file = assert(io.open(path, "r"))
    local content = file:read("*all")
    file:close()

    if content == "" then
        return {}
    end

    return json.decode(content)
end

function M:writeToListFile(list)
    local path = self.directory .. "/" .. self.LIST_FILE_NAME

    local file = assert(io.open(path, "w"))
    file:write(json.encode(list))
    file:close()
end


return M
