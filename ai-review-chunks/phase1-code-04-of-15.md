# PHASE1 PART 4/15

   79:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
   80:                 "D:\\Тест\\**": "allow"
   81:             },
   82:             "glob": "allow",
   83:             "grep": "allow",
   84:             "read": "allow",
   85:             "skill": "allow",
   86:             "task": "deny"
   87:         },
   88:         "prompt": "{file:.opencode/agents/prompts/backend-1.txt}"
   89:     }
   90: ,
   91:     "backend": {
   92:         "description": "Backend Specialist — REST/GraphQL API, бизнес-логика, middleware, авторизация.",
   93:         "mode": "subagent",
   94:         "model": "tokenrouter/z-ai/glm-5.3-free",
   95:         "temperature": 0.2,
   96:         "permission": {
   97:             "bash": "allow",
   98:             "edit": "allow",
   99:             "external_directory": {
  100:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  101:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  102:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  103:                 "D:\\Тест\\**": "allow"
  104:             },
  105:             "glob": "allow",
  106:             "grep": "allow",
  107:             "read": "allow",
  108:             "skill": "allow",
  109:             "task": "deny"
  110:         },
```

### `opencode.json` lines 610-854

```json
  610:             "skill": "allow",
  611:             "task": "deny",
  612:             "webfetch": "allow"
  613:         },
  614:         "prompt": "{file:.opencode/agents/prompts/smm-strategist.txt}"
  615:     }
  616: ,
  617:     "team-lead-1": {
  618:         "description": "Team Lead (copy 1) — оркестратор для параллельной оркестрации.",
  619:         "mode": "subagent",
  620:         "model": "tokenrouter/z-ai/glm-5.3-free",
  621:         "temperature": 0.1,
  622:         "permission": {
  623:             "bash": "allow",
  624:             "edit": "allow",
  625:             "external_directory": {
  626:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  627:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  628:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  629:                 "D:\\Тест\\**": "allow"
  630:             },
  631:             "glob": "allow",
  632:             "grep": "allow",
  633:             "question": "allow",
  634:             "read": "allow",
  635:             "skill": "allow",
  636:             "task": "deny"
  637:         },
  638:         "prompt": "{file:.opencode/agents/prompts/team-lead-1.txt}"
  639:     }
  640: ,
  641:     "team-lead-2": {
  642:         "description": "Team Lead (copy 2) — оркестратор для параллельной оркестрации.",
  643:         "mode": "subagent",
  644:         "model": "tokenrouter/z-ai/glm-5.3-free",
  645:         "temperature": 0.1,
  646:         "permission": {
  647:             "bash": "allow",
  648:             "edit": "allow",
  649:             "external_directory": {
  650:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  651:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  652:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  653:                 "D:\\Тест\\**": "allow"
  654:             },
  655:             "glob": "allow",
  656:             "grep": "allow",
  657:             "question": "allow",
  658:             "read": "allow",
  659:             "skill": "allow",
  660:             "task": "deny"
  661:         },
  662:         "prompt": "{file:.opencode/agents/prompts/team-lead-2.txt}"
  663:     }
  664: ,
  665:     "team-lead-3": {
  666:         "description": "Team Lead (copy 3) — оркестратор для параллельной оркестрации.",
  667:         "mode": "subagent",
  668:         "model": "tokenrouter/z-ai/glm-5.3-free",
  669:         "temperature": 0.1,
  670:         "permission": {
  671:             "bash": "allow",
  672:             "edit": "allow",
  673:             "external_directory": {
  674:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  675:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  676:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  677:                 "D:\\Тест\\**": "allow"
  678:             },
  679:             "glob": "allow",
  680:             "grep": "allow",
  681:             "question": "allow",
  682:             "read": "allow",
  683:             "skill": "allow",
  684:             "task": "deny"
  685:         },
  686:         "prompt": "{file:.opencode/agents/prompts/team-lead-3.txt}"
  687:     }
  688: ,
  689:     "team-lead": {
  690:         "description": "Team Lead — оркестратор мультиагентной команды. Декомпозирует задачи, назначает агентов, контролирует качество.",
  691:         "mode": "subagent",
  692:         "model": "tokenrouter/z-ai/glm-5.3-free",
  693:         "temperature": 0.1,
  694:         "permission": {
  695:             "bash": "allow",
  696:             "edit": "allow",
  697:             "external_directory": {
  698:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  699:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  700:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  701:                 "D:\\Тест\\**": "allow"
  702:             },
  703:             "glob": "allow",
  704:             "grep": "allow",
  705:             "question": "allow",
  706:             "read": "allow",
  707:             "skill": "allow",
  708:             "task": "deny"
  709:         },
  710:         "prompt": "{file:.opencode/agents/prompts/team-lead.txt}"
  711:     }
  712: ,
  713:     "tech-writer-1": {
  714:         "description": "Tech Writer (copy 1) — README, API docs, changelog, архитектурная документация для параллельной работы.",
  715:         "mode": "subagent",
  716:         "model": "tokenrouter/z-ai/glm-5.3-free",
  717:         "temperature": 0.2,
  718:         "permission": {
  719:             "bash": "deny",
  720:             "edit": "allow",
  721:             "external_directory": {
  722:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  723:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  724:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  725:                 "D:\\Тест\\**": "allow"
  726:             },
  727:             "glob": "allow",
  728:             "grep": "allow",
  729:             "read": "allow",
  730:             "task": "deny"
  731:         },
  732:         "prompt": "{file:.opencode/agents/prompts/tech-writer-1.txt}"
  733:     }
  734: ,
  735:     "tech-writer": {
  736:         "description": "Tech Writer — генерирует README, API docs, changelog, архитектурную документацию.",
  737:         "mode": "subagent",
  738:         "model": "tokenrouter/z-ai/glm-5.3-free",
  739:         "temperature": 0.2,
  740:         "permission": {
  741:             "bash": "deny",
  742:             "edit": "allow",
  743:             "external_directory": {
  744:                 "C:\\Users\\Ermak_DS\\.config\\opencode\\**": "allow",
  745:                 "C:\\Users\\Ermak_DS\\.local\\share\\opencode\\**": "allow",
  746:                 "C:\\Users\\Ermak_DS\\AppData\\Local\\opencode\\**": "allow",
  747:                 "D:\\Тест\\**": "allow"
  748:             },
  749:             "glob": "allow",
  750:             "grep": "allow",
  751:             "read": "allow",
  752:             "task": "deny"
  753:         },
  754:         "prompt": "{file:.opencode/agents/prompts/tech-writer.txt}"
  755:     }
  756: 
  757:   },
  758:   "memory": {
  759:     "bank_path": ".memory/",
  760:     "archive_ttl_days": 7,
  761:     "compression": {
  762:       "enabled": true,
  763:       "max_size_kb": 50,
  764:       "strategy": "summary+archive"
  765:     }
  766:   },
  767:   "compaction": {
  768:     "auto": true,
  769:     "prune": true,
  770:     "tail_turns": 12
  771:   },
  772:   "watcher": {
  773:     "ignore": [
  774:       ".memory/**",
  775:       ".agents/worktrees/**"
  776:     ]
  777:   },
  778:   "workspace": {
  779:     "root": "D:\\Тест\\agent-hq",
  780:     "sandbox_per_agent": true,
  781:     "merge_strategy": "git-branch"
  782:   },
  783:   "projects": {
  784:     "news-bot": {
  785:       "type": "telegram-bot",
  786:       "agents": [
  787:         "backend",
  788:         "devops",
  789:         "qa-engineer",
  790:         "tech-writer"
  791:       ]
  792:     },
  793:     "pong-advanced": {
  794:       "type": "full-stack",
  795:       "agents": [
  796:         "frontend",
  797:         "backend",
  798:         "devops",
  799:         "qa-engineer"
  800:       ]
  801:     }
  802:   },
  803:   "modules": {
  804:     "memory_bank": true,
  805:     "agent_sandbox": true,
  806:     "model_router": true,
  807:     "context_compression": true,
  808:     "distributed_tracing": true,
  809:     "performance_scoring": true,
  810:     "plugins": true,
  811:     "health_monitoring": true
  812:   },
  813:   "provider": {
  814:     "tokenrouter": {
  815:       "sdk": "@ai-sdk/openai-compatible",
  816:       "options": {
  817:         "baseURL": "https://api.tokenrouter.com/v1",
  818:         "apiKey": "{env:TOKENROUTER_API_KEY}"
  819:       },
  820:       "models": {
  821:         "z-ai/glm-5.3-free": {
  822:           "name": "GLM 5.3 Free (TokenRouter)"
  823:         },
  824:         "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free": {
  825:           "name": "Nemotron 3 Nano Omni Reasoning Free (TokenRouter)"
  826:         }
  827:       }
  828:     },
  829:     "openrouter": {
  830:       "models": {
  831:         "nvidia/nemotron-3.5-lightning:free": {
  832:           "name": "Nemotron Lightning (free)"
  833:         },
  834:         "nvidia/nemotron-3-ultra-550b-a55b:free": {
  835:           "name": "Nemotron Ultra (free)"
  836:         },
  837:         "z-ai/glm-5.2:free": {
  838:           "name": "GLM 5.2 (free)"
  839:         },
  840:         "cohere/north-mini-code:free": {
  841:           "name": "North Mini Code (free)"
  842:         }
  843:       }
  844:     }
  845:   },
  846:   "permission": {
  847:     "external_directory": {
  848:       "D:\\\\Тест\\\\**": "allow",
  849:       "C:\\\\Users\\\\Ermak_DS\\\\.local\\\\share\\\\opencode\\\\**": "allow",
  850:       "C:\\\\Users\\\\Ermak_DS\\\\AppData\\\\Local\\\\opencode\\\\**": "allow",
  851:       "C:\\\\Users\\\\Ermak_DS\\\\.config\\\\opencode\\\\**": "allow"
  852:     }
  853:   }
  854: }
```

### `.github/workflows/verify.yml` lines 1-38

```yaml
    1: name: verify
    2: 
    3: on:
    4:   push:
    5:     branches: [main, master]
    6:   pull_request:
    7:     branches: [main, master]
    8:   workflow_dispatch:
    9: 
   10: jobs:
   11:   verify:
   12:     runs-on: windows-latest
   13:     steps:
   14:       - name: Checkout
   15:         uses: actions/checkout@v4
   16: 
   17:       - name: Run verify-phase.ps1
   18:         shell: pwsh
   19:         working-directory: ${{ github.workspace }}
   20:         run: |
   21:           Write-Host "=== Running agent-hq phase verification ==="
   22:           & .\.agents\scripts\verify-phase.ps1
   23:           $code = $LASTEXITCODE
   24:           if ($code -ne 0) {
   25:             Write-Host "::error::verify-phase.ps1 reported failures (exit $code)"
   26:             exit $code
   27:           }
   28:           Write-Host "=== Verification passed ==="
   29: 
   30:       - name: Upload verify log
   31:         if: always()
   32:         uses: actions/upload-artifact@v4
   33:         with:
   34:           name: verify-log
   35:           path: |
   36:             .memory/
   37:             CONTEXT-BUFFER.md
   38:           retention-days: 7
```

### `.opencode/agents/team-lead.json` lines 1-20

```json
    1: {
    2:     "name":  "team-lead",
    3:     "description":  "Team Lead — оркестратор мультиагентной команды. Декомпозирует задачи, назначает агентов, контролирует качество.",
    4:     "model":  "tokenrouter/z-ai/glm-5.3-free",
    5:     "mode":  "subagent",
    6:     "temperature":  0.1,
    7:     "permissions":  [
    8:                         "edit",
    9:                         "bash",
   10:                         "read",
   11:                         "glob",
   12:                         "grep",
   13:                         "skill",
   14:                         "question"
   15:                     ],
   16:     "division":  "Management(team-lead)",
   17:     "deliverable":  "Задачи назначены + решения записаны в буфер",
   18:     "success_metric":  "Все под-задачи выполнены со STATUS: resolved",


---
Ответь только: `Принято 4/15`. Жди следующую часть.
