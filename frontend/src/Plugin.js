import React, { useEffect, useRef, useState } from 'react'
import { Link, LinkText } from '@gluestack-ui/themed'
import {
  api,
  useAlert,
  Page,
  ListHeader,
  Card,
  SectionHeader,
  StatTile,
  KeyVal,
  StatusDot,
  Toggle,
  ModalConfirm,
  Loading,
  Button,
  ButtonText,
  Box,
  Text,
  ScrollView,
  HStack,
  VStack
} from '@spr-networks/plugin-ui'

const PLUGIN_BASE = `/plugins/${api.pluginURI() || 'spr-atlas'}`
const REGISTER_URL_FALLBACK = 'https://atlas.ripe.net/apply/swprobe/'
const probeOverviewURL = (probeID) =>
  `https://atlas.ripe.net/probes/${probeID}/overview`

const fmtUptime = (secs) => {
  if (!secs || secs < 0) return '—'
  const d = Math.floor(secs / 86400)
  const h = Math.floor((secs % 86400) / 3600)
  const m = Math.floor((secs % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m ${secs % 60}s`
}

const copyText = (text) => {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text)
  }
  return new Promise((resolve, reject) => {
    try {
      const el = document.createElement('textarea')
      el.value = text
      el.style.position = 'fixed'
      el.style.opacity = '0'
      document.body.appendChild(el)
      el.focus()
      el.select()
      document.execCommand('copy')
      document.body.removeChild(el)
      resolve()
    } catch (e) {
      reject(e)
    }
  })
}

// Rough severity classification of a probe log line, for row tinting only.
const logLevel = (line) => {
  if (/\b(error|fatal|fail|failed|failure|refused|denied|cannot|unable)\b/i.test(line))
    return 'error'
  if (/\b(warn|warning|retry|retrying|timeout|timed out|disconnect)\b/i.test(line))
    return 'warn'
  return 'info'
}

const logColors = {
  error: { light: '$red600', dark: '$red400' },
  warn: { light: '$amber600', dark: '$amber400' },
  info: { light: '$muted600', dark: '$muted400' }
}

const Step = ({ n, children }) => (
  <HStack space="md" alignItems="flex-start">
    <Box
      w={22}
      h={22}
      mt="$0.5"
      flexShrink={0}
      borderRadius="$full"
      alignItems="center"
      justifyContent="center"
      bg="$primary700"
      sx={{ _dark: { bg: '$primary500' } }}
    >
      <Text size="2xs" color="$white" fontWeight="$bold">
        {n}
      </Text>
    </Box>
    <Text size="sm" color="$muted600" lineHeight="$sm" flexShrink={1} sx={{ _dark: { color: '$muted300' } }}>
      {children}
    </Text>
  </HStack>
)

const MonoBlock = ({ children }) => (
  <Box
    p="$3"
    borderRadius="$md"
    borderWidth={1}
    borderColor="$borderColorCardLight"
    bg="$backgroundContentLight"
    sx={{
      _dark: {
        bg: '$backgroundContentDark',
        borderColor: '$borderColorCardDark'
      }
    }}
  >
    {children}
  </Box>
)

export default function Plugin() {
  const alert = useAlert()
  const [status, setStatus] = useState(null)
  const [keyInfo, setKeyInfo] = useState(null)
  const [logs, setLogs] = useState([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState(false)
  const [showRestart, setShowRestart] = useState(false)
  const [restarting, setRestarting] = useState(false)
  const [autoRefresh, setAutoRefresh] = useState(true)
  const autoRef = useRef(true)
  autoRef.current = autoRefresh

  const fetchLogs = () => {
    api
      .get(`${PLUGIN_BASE}/logs?lines=200`)
      .then((lg) => setLogs(lg?.Lines || []))
      .catch(() => {})
  }

  const refresh = (initial = false) => {
    Promise.allSettled([
      api.get(`${PLUGIN_BASE}/status`),
      api.get(`${PLUGIN_BASE}/key`)
    ]).then(([st, key]) => {
      if (st.status === 'fulfilled') {
        setStatus(st.value)
        setLoadError(false)
      } else if (initial) {
        setLoadError(true)
      }
      if (key.status === 'fulfilled') setKeyInfo(key.value)
      setLoading(false)
    })
    if (initial || autoRef.current) fetchLogs()
  }

  useEffect(() => {
    refresh(true)
    const timer = setInterval(refresh, 10000)
    return () => clearInterval(timer)
  }, [])

  const doRestart = () => {
    setShowRestart(false)
    setRestarting(true)
    api
      .post(`${PLUGIN_BASE}/restart`)
      .then(() => {
        alert.success('Probe restarting')
        setTimeout(() => {
          refresh()
          setRestarting(false)
        }, 2000)
      })
      .catch((err) => {
        setRestarting(false)
        alert.error('Failed to restart probe', err)
      })
  }

  const doCopyKey = () => {
    if (!keyInfo?.PublicKey) return
    copyText(keyInfo.PublicKey)
      .then(() => alert.success('Public key copied to clipboard'))
      .catch(() => alert.error('Copy failed — select the key text manually'))
  }

  const openRegistration = () => {
    window.open(keyInfo?.RegisterURL || REGISTER_URL_FALLBACK, '_blank')
  }

  if (loading) {
    return (
      <Page>
        <Loading />
      </Page>
    )
  }

  if (!status && loadError) {
    return (
      <Page>
        <ListHeader
          title="RIPE Atlas Probe"
          description="Software probe measuring internet connectivity for the RIPE Atlas network"
          mark="ra"
        />
        <Card>
          <SectionHeader title="Backend unreachable" right={<StatusDot />} />
          <Text size="sm" color="$muted500" mb="$4">
            The plugin backend did not respond. It may still be starting — if
            this persists, check that the spr-atlas container is running.
          </Text>
          <HStack>
            <Button size="sm" onPress={() => refresh(true)}>
              <ButtonText>Retry</ButtonText>
            </Button>
          </HStack>
        </Card>
      </Page>
    )
  }

  const running = !!status?.Running
  const connected = !!status?.Connected
  const registered = !!status?.Registered || connected
  const stateWord = !running
    ? 'Stopped'
    : connected
    ? 'Connected'
    : registered
    ? 'Connecting'
    : 'Awaiting approval'
  const controller = status?.ControllerHost
    ? status.ControllerHost + (status?.ControllerPort ? `:${status.ControllerPort}` : '')
    : null
  const probeID = Number.isInteger(status?.ProbeID) && status.ProbeID > 0
    ? status.ProbeID
    : null

  const restartButton = (
    <Button
      size="xs"
      variant="outline"
      action="negative"
      isDisabled={restarting}
      onPress={() => setShowRestart(true)}
    >
      <ButtonText>{restarting ? 'Restarting…' : 'Restart probe'}</ButtonText>
    </Button>
  )

  return (
    <Page>
      <ListHeader
        title="RIPE Atlas Probe"
        description="Software probe measuring internet connectivity for the RIPE Atlas network"
        mark="ra"
        status={stateWord}
        statusAction={connected ? 'success' : running ? 'warning' : 'muted'}
      />

      {!running ? (
        <Card tone="warning">
          <SectionHeader title="Probe stopped" right={restartButton} />
          <Text size="sm" color="$muted600" mb="$1" sx={{ _dark: { color: '$muted300' } }}>
            The probe process is not running. The supervisor restarts it
            automatically; if it keeps exiting, the log below usually says why.
          </Text>
          {status?.LastExit ? (
            <KeyVal label="Last exit" value={status.LastExit} mono />
          ) : null}
        </Card>
      ) : null}

      {registered ? (
        <>
          <Card>
            <SectionHeader title="Overview" right={running ? restartButton : null} />
            <HStack space="sm" alignItems="center" mb="$4" flexWrap="wrap">
              <StatusDot online={connected} warn={running && !connected} />
              <Text
                size="md"
                fontWeight="$semibold"
                color="$textLight900"
                sx={{ _dark: { color: '$textDark50' } }}
              >
                {stateWord}
              </Text>
              {controller ? (
                <Text size="sm" color="$muted500" sx={{ '@base': { fontFamily: 'monospace' } }}>
                  {controller}
                </Text>
              ) : null}
            </HStack>
            <HStack flexWrap="wrap" gap="$2">
              <StatTile label="Uptime" value={fmtUptime(status?.UptimeSeconds)} mono />
              <StatTile label="Version" value={status?.Version || '—'} mono />
              <StatTile label="Restarts" value={String(status?.Restarts ?? 0)} mono />
            </HStack>
            <VStack space="sm" mt="$4">
              {controller ? (
                <KeyVal label="Assigned controller" value={controller} mono />
              ) : null}
              {!connected ? (
                <Text size="xs" color="$muted500">
                  The probe reconnects to its controller on its own — no action
                  needed unless this state persists for hours.
                </Text>
              ) : null}
            </VStack>
          </Card>

          <Card>
            <SectionHeader
              title="Identity"
              right={
                keyInfo?.Exists ? (
                  <Button size="xs" variant="outline" onPress={doCopyKey}>
                    <ButtonText>Copy public key</ButtonText>
                  </Button>
                ) : null
              }
            />
            <VStack space="sm">
              {probeID ? (
                <VStack space="xs">
                  <KeyVal label="Probe ID" value={String(probeID)} mono />
                  <Link isExternal href={probeOverviewURL(probeID)}>
                    <LinkText>Open probe {probeID} on RIPE Atlas</LinkText>
                  </Link>
                </VStack>
              ) : null}
              <KeyVal
                label="Fingerprint"
                value={keyInfo?.Fingerprint || status?.Fingerprint || '—'}
                mono
              />
              <Text size="xs" color="$muted500">
                The probe key is its permanent identity and is already on file
                with RIPE. You only need the public key again when contacting
                Atlas support.
              </Text>
            </VStack>
          </Card>
        </>
      ) : (
        <Card>
          <SectionHeader
            title="Register this probe"
            right={<StatusDot warn={running && !!keyInfo?.Exists} />}
          />
          <VStack space="md">
            <Text size="sm" color="$muted500" lineHeight="$sm">
              Hosting a probe contributes measurements from your network to the
              RIPE Atlas platform and earns credits to run your own. One-time
              setup:
            </Text>
            <Step n="1">Copy the probe public key below.</Step>
            <Step n="2">
              Submit it on the RIPE Atlas software probe application page —
              sign in with a free RIPE NCC Access account.
            </Step>
            <Step n="3">
              Wait for approval. The probe connects on its own — the status
              here typically turns Connected within a few minutes of approval.
              No restart needed; this page refreshes automatically.
            </Step>
            {keyInfo?.Exists ? (
              <VStack space="md" mt="$1">
                <MonoBlock>
                  <Text size="xs" fontFamily="$mono" selectable>
                    {keyInfo.PublicKey}
                  </Text>
                </MonoBlock>
                <KeyVal label="Fingerprint" value={keyInfo.Fingerprint} mono />
                <HStack space="md" flexWrap="wrap">
                  <Button size="sm" onPress={doCopyKey}>
                    <ButtonText>Copy public key</ButtonText>
                  </Button>
                  <Button size="sm" variant="outline" onPress={openRegistration}>
                    <ButtonText>Open registration page</ButtonText>
                  </Button>
                </HStack>
              </VStack>
            ) : (
              <Text size="sm" color="$muted500">
                No probe key yet — it is generated on the plugin's first start.
                Check the probe log below if this persists.
              </Text>
            )}
          </VStack>
        </Card>
      )}

      <Card>
        <SectionHeader
          title="Probe log"
          count={logs.length}
          right={
            <HStack space="sm" alignItems="center">
              <Text size="xs" color="$muted500">
                Auto-refresh
              </Text>
              <Toggle
                value={autoRefresh}
                onPress={() => {
                  const next = !autoRefresh
                  setAutoRefresh(next)
                  if (next) fetchLogs()
                }}
                label="Auto-refresh probe log"
              />
            </HStack>
          }
        />
        {logs.length ? (
          <ScrollView
            maxHeight={320}
            px="$3"
            py="$2"
            borderRadius="$md"
            borderWidth={1}
            borderColor="$borderColorCardLight"
            bg="$backgroundContentLight"
            sx={{
              _dark: {
                bg: '$backgroundContentDark',
                borderColor: '$borderColorCardDark'
              }
            }}
          >
            <VStack>
              {logs.map((line, i) => {
                const level = logLevel(line)
                return (
                  <Text
                    key={i}
                    size="xs"
                    py="$0.5"
                    fontFamily="$mono"
                    lineHeight="$sm"
                    color={logColors[level].light}
                    sx={{ _dark: { color: logColors[level].dark } }}
                  >
                    {line}
                  </Text>
                )
              })}
            </VStack>
          </ScrollView>
        ) : (
          <Text size="sm" color="$muted500">
            No log output captured yet.
          </Text>
        )}
        <Text size="2xs" color="$muted400" mt="$2">
          Sanitized tail — control characters stripped, key material redacted.
        </Text>
      </Card>

      <ModalConfirm
        isOpen={showRestart}
        onClose={() => setShowRestart(false)}
        onConfirm={doRestart}
        title="Restart the probe?"
        message="Measurements in flight are dropped. The probe reconnects to its controller automatically; the probe key is not affected."
        confirmText="Restart"
        destructive
      />
    </Page>
  )
}
