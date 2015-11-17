local M = class("MainView", neon.View)


function M:onCreate()
    neon.logger:error("onCreate %s", self.__cname)

    local layer = cc.LayerColor:create(cc.c4b(0,0,255,255))
    self.root:addChild(layer)

    self.downloader = require("downloader.Downloader").new("download", 10, 10)

    for i=1, 1, 1 do
        self:download()
    end
    -- neon.logger:debug("removeTask: " .. tostring(self.downloader:removeTask(3)))
end

function M:download()
    -- local url = "http://127.0.0.1:5000/x"
    -- local url = "http://bbs.unpcn.com/attachment.aspx?attachmentid=4330041"
    local url = "http://bbs.unpcn.com/attachment.aspx?attachmentid=4330045"

    local taskID = self.downloader:execute(url, 5,
        function (path)
            neon.logger:debug(path)

            -- self.downloader:removeFile(url)
        end, 
        function (code)
            neon.logger:debug(code)
        end,
        function ()
            neon.logger:debug()
        end
    )

    neon.logger:debug(taskID)
end

function M:onRemove()
    neon.logger:error("onRemove %s", self.__cname)
end

function M:onRender(params)
    neon.logger:debug("params: %s", tostring(params))
end

return M
