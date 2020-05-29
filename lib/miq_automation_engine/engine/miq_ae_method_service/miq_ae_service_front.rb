module MiqAeMethodService
  class MiqAeServiceFront
    attr_accessor :workspace
    def initialize(workspace)
      @workspace = workspace
    end

    def self.connect_and_find(url, api_token, service_id)

    end

    def find(id)
      MiqAeService.find(id)
    end
  end
end
