import { EventEmitter } from 'events'
import { getIPAddress } from './utils'
import { SoundModes } from "./types"
import { constants } from './constants'
import { startBalenaService, stopBalenaService, restartBalenaService } from './utils'
import BalenaAudio from 'balena-audio'

interface MultiRoomConfig {
  master: String,
  forced: boolean
}

interface DeviceConfig {
  ip: string,
  type: string
}

const PLUGINS: string[] = ['airplay', 'spotify', 'upnp', 'bluetooth']

export default class SoundConfig {
  public mode: SoundModes = constants.mode
  public device: DeviceConfig = {
    ip: getIPAddress() ?? 'localhost',
    type: constants.balenaDeviceType
  }
  public multiroom: MultiRoomConfig = {
    master: constants.multiroom.master ?? this.device.ip,
    forced: constants.multiroom.forced
  }

  // Kept non-enumerable so they are not exposed as API routes or serialized in /config and /support
  private audioBlock!: BalenaAudio
  private events!: EventEmitter

  constructor() {
    Object.defineProperty(this, 'audioBlock', { enumerable: false, writable: true, value: undefined })
    Object.defineProperty(this, 'events', { enumerable: false, writable: false, value: new EventEmitter() })
  }

  bindAudioBlock(audioBlock: BalenaAudio) {
    this.audioBlock = audioBlock
  }

  onModeChange(listener: (mode: SoundModes, oldMode: SoundModes) => void) {
    this.events.on('mode-change', listener)
  }

  setMultiRoomMaster(master: string) {
    this.multiroom.master = master
    restartBalenaService('multiroom-client')
  }

  // Re-read the device IP address. Returns true if it changed.
  // If the device was using its own IP as multi-room master, the master is updated as well
  refreshIPAddress(): boolean {
    const ip = getIPAddress()
    if (!ip || ip === this.device.ip) {
      return false
    }

    if (!this.multiroom.forced && this.multiroom.master === this.device.ip) {
      this.multiroom.master = ip
    }
    this.device.ip = ip
    return true
  }

  setMode(mode: SoundModes): boolean {
    if (!mode || !Object.values(SoundModes).includes(mode)) {
      console.log(`Error setting mode, invalid mode: ${mode}`)
      return false
    }

    const oldMode: SoundModes = this.mode
    if (mode === oldMode) {
      return false
    }

    this.mode = SoundModes[mode]

    switch (this.mode) {
      case SoundModes.MULTI_ROOM:
        startBalenaService('multiroom-server')
        startBalenaService('multiroom-client')
        startPlugins()
        this.routeInputSink('snapcast')
        break
      case SoundModes.MULTI_ROOM_CLIENT:
        stopBalenaService('multiroom-server')
        stopPlugins()
        startBalenaService('multiroom-client')
        this.routeInputSink('balena-sound.output')
        break
      case SoundModes.STANDALONE:
        stopBalenaService('multiroom-server')
        stopBalenaService('multiroom-client')
        startPlugins()
        this.routeInputSink('balena-sound.output')
        break
      default:
        break
    }

    this.events.emit('mode-change', this.mode, oldMode)
    return true
  }

  // Move the "balena-sound.input" loopback to the given sink. Sinks and sink inputs are looked up by name,
  // since their indexes change depending on which soundcards (USB, DAC, HDMI...) are present
  private async routeInputSink(sinkName: string): Promise<void> {
    try {
      const sinks: any[] = await this.audioBlock.getSinks()
      const sink = sinks.find(s => s.name === sinkName)
      if (!sink) {
        console.log(`Error routing audio: sink '${sinkName}' not found`)
        return
      }

      const sinkInputs: any[] = await this.audioBlock.getSinkInputs()
      const loopback = sinkInputs.find(i => typeof i.name === 'string' && i.name.startsWith('Loopback') && i.name.includes(constants.inputSink))
      if (!loopback) {
        console.log(`Error routing audio: '${constants.inputSink}' loopback not found`)
        return
      }

      if (loopback.sinkIndex !== sink.index) {
        await this.audioBlock.moveSinkInput(loopback.index, sink.index)
        console.log(`Routing '${constants.inputSink}' to '${sinkName}'.`)
      }
    } catch (error) {
      console.log(`Error routing audio to '${sinkName}': ${error.message ?? error}`)
    }
  }

  isMultiRoomEnabled(): boolean {
    let mrModes: SoundModes[] = [SoundModes.MULTI_ROOM, SoundModes.MULTI_ROOM_CLIENT]
    return mrModes.includes(this.mode)
  }

  isMultiRoomServer(): boolean {
    let mrModes: SoundModes[] = [SoundModes.MULTI_ROOM]
    return mrModes.includes(this.mode)
  }

  isMultiRoomMaster(): boolean {
    return this.isMultiRoomServer() && this.device.ip === this.multiroom.master
  }

  isNewMultiRoomMaster(master: string): boolean {
    return this.isMultiRoomEnabled() && this.multiroom.master !== master
  }

}

// Plugins disabled with SOUND_DISABLE_<PLUGIN> are not started when switching modes
function isPluginDisabled(plugin: string): boolean {
  return !!process.env[`SOUND_DISABLE_${plugin.toUpperCase()}`]
}

function startPlugins() {
  PLUGINS.filter(p => !isPluginDisabled(p)).forEach(p => startBalenaService(p))
}

function stopPlugins() {
  PLUGINS.forEach(p => stopBalenaService(p))
}
