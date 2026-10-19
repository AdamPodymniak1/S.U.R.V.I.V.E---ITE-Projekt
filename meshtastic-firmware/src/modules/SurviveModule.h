#pragma once
#include "SinglePortModule.h"
#include "concurrency/OSThread.h"
#include "NodeDB.h"

class SurviveModule : public SinglePortModule, private concurrency::OSThread
{
  public:
    SurviveModule();
    virtual ~SurviveModule() {}

    bool isSurvivalMode() const { return survivalMode; }
    void setSurvivalMode(bool enabled);

    bool shouldSuppressPacket(const meshtastic_MeshPacket *p) const;

    void sendNodePositionReport(NodeNum dest = NODENUM_BROADCAST);

  protected:
    virtual int32_t runOnce() override;
    virtual ProcessMessage handleReceived(const meshtastic_MeshPacket &mp) override;

  private:
    bool survivalMode;
    uint32_t lastReportSecs;

    static const uint32_t REPORT_INTERVAL_SECS = 300; // 5 minutes
};

extern SurviveModule *surviveModule;